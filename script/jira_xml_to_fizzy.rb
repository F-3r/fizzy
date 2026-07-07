#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "cgi"
require "time"
require "set"
require "optparse"
require "fileutils"
require "base64"
require "rexml/parsers/pullparser"
require_relative "../lib/fizzy_client"

class JiraXmlToFizzy
  DEFAULT_STATE_PATH = "tmp/jira_xml_to_fizzy_state.json"
  OPEN_STATUS_CATEGORIES = %w[2 4].freeze
  CLOSED_STATUS_CATEGORIES = %w[3].freeze
  INLINE_ATTACHMENT_PATTERNS = [
    /\[\^([^\]]+)\]/,
    /!([^!|]+)(?:\|[^!]*)?!/
  ].freeze
  DATA_IMAGE_PATTERN = /!\[[^\]]*\]\((data:image\/[^;]+;base64,[^)]+)\)/m

  def initialize(options)
    @options = options
    @client = Fizzy::Client.new(
      base_url: options.fetch(:base_url),
      bearer_token: options.fetch(:token),
      account_slug: options.fetch(:account_slug),
      user_agent: "jira-xml-to-fizzy"
    )
    @state = load_state
    @scan = @state["scan"] || fresh_scan
  end

  def run
    scan_export! unless @state["scan_complete"]
    @selected_issue_ids_for_run = Set.new

    if @options[:preflight]
      run_preflight!
    else
      ensure_boards!
      import_issues!
      import_comments!
      save_state!
      puts "Done"
    end
  end

  private
    def fresh_scan
      {
        "projects" => {},
        "statuses" => {},
        "issue_types" => {},
        "users" => {},
        "issues_by_project" => Hash.new { |h, k| h[k] = [] },
        "status_ids_by_project" => Hash.new { |h, k| h[k] = [] },
        "attachments_by_issue" => Hash.new { |h, k| h[k] = [] }
      }
    end

    def load_state
      path = @options.fetch(:state_path)
      return default_state unless File.exist?(path)

      JSON.parse(File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace))
    end

    def default_state
      {
        "boards" => {},
        "cards" => {},
        "comments" => {}
      }
    end

    def save_state!
      @state["scan"] = @scan
      FileUtils.mkdir_p(File.dirname(@options.fetch(:state_path)))
      File.write(@options.fetch(:state_path), JSON.pretty_generate(@state))
    end

    def scan_export!
      puts "Scanning #{@options[:xml_path]} ..."

      each_record do |type, record|
        case type
        when "Project"
          @scan["projects"][record.fetch("id")] = slice(record, "id", "key", "name", "description")
        when "Status"
          @scan["statuses"][record.fetch("id")] = slice(record, "id", "name", "statuscategory", "sequence", "scope", "projectconfigurationid")
        when "IssueType"
          @scan["issue_types"][record.fetch("id")] = slice(record, "id", "name", "hierarchy_level")
        when "User"
          @scan["users"][record.fetch("userName")] = slice(record, "userName", "displayName", "emailAddress", "active")
        when "Issue"
          project_key = record["projectKey"]
          @scan["issues_by_project"][project_key] << record.fetch("id")
          @scan["status_ids_by_project"][project_key] << record["status"] if record["status"]
        when "FileAttachment"
          @scan["attachments_by_issue"][record.fetch("issue")] << slice(record, "id", "issue", "mimetype", "filename", "created", "filesize", "author", "parentField")
        end
      end

      @scan["status_ids_by_project"].each_value(&:uniq!)
      @state["scan_complete"] = true
      save_state!
      puts "Scan complete"
    end

    def run_preflight!
      puts "Preflight ..."
      ensure_boards!
      preload_fizzy_users!
      report_user_mapping!
      report_column_mapping!
      save_state!
      puts "Preflight done"
    end

    def ensure_boards!
      @scan.fetch("projects").each_value do |project|
        next unless relevant_project_keys.include?(project.fetch("key"))

        board_state_key = board_state_key_for(project.fetch("key"))
        unless @state.dig("boards", board_state_key, "board_id")
          board_name = board_name_for(project)
          existing_board = find_board_by_name(board_name)

          @state["boards"][board_state_key] = {
            "board_id" => existing_board ? existing_board.fetch("id") : nil,
            "columns_by_status_id" => {}
          }

          if existing_board
            puts "Using existing board for #{project.fetch("key")}: #{board_name}"
          else
            puts "Creating board for #{project.fetch("key")}" 
            response = @client.create_board(
              name: board_name,
              all_access: true,
              public_description: board_description(project)
            )
            assert_success!(response, "create board #{project.fetch("key")}")
            @state["boards"][board_state_key]["board_id"] = response.body.fetch("id")
          end
        end

        create_columns_for_project!(project.fetch("key"))
        save_state!
      end
    end

    def create_columns_for_project!(project_key)
      board_state_key = board_state_key_for(project_key)
      board_id = @state.dig("boards", board_state_key, "board_id")
      status_ids = Array(@scan.dig("status_ids_by_project", project_key))
      statuses = status_ids.filter_map { |id| @scan.dig("statuses", id) }
      open_statuses = statuses.select { |status| OPEN_STATUS_CATEGORIES.include?(status["statuscategory"].to_s) }
      ordered = open_statuses.sort_by { |status| [status["sequence"].to_i, status["name"].to_s.downcase] }

      existing_columns = @client.list_columns(board_id: board_id)
      assert_success!(existing_columns, "list columns for #{project_key}")
      used_names = Array(existing_columns.body).map { |column| column["name"] }.to_set

      ordered.each do |status|
        next if @state.dig("boards", board_state_key, "columns_by_status_id", status.fetch("id"))

        column_name = unique_name(status.fetch("name"), used_names)
        response = @client.create_column(board_id: board_id, name: column_name)
        assert_success!(response, "create column #{project_key}:#{status.fetch("name")}")
        @state["boards"][board_state_key]["columns_by_status_id"][status.fetch("id")] = response.body.fetch("id")
      end
    end

    def import_issues!
      puts "Importing issues ..."

      imported = 0
      each_record do |type, issue|
        next unless type == "Issue"
        next unless issue_selected?(issue)
        next if @state.dig("cards", issue.fetch("id"), "card_number")
        break if import_limit && imported >= import_limit

        import_issue!(issue)
        @selected_issue_ids_for_run << issue.fetch("id")
        imported += 1
        save_state!
      end
    end

    def import_issue!(issue)
      project_key = issue.fetch("projectKey")
      board_id = @state.dig("boards", board_state_key_for(project_key), "board_id")
      issue_key = "#{project_key}-#{issue.fetch("number")}"
      puts "  card #{issue_key}"

      issue_key = "#{project_key}-#{issue.fetch("number")}"
      issue_with_embeds, embedded_uploads = replace_embedded_data_images(
        text: issue["description"].to_s,
        scope_key: issue_key,
        parent_field: "description"
      )

      uploaded = upload_issue_attachments(issue).merge(embedded_uploads)
      issue = issue.merge("description" => issue_with_embeds)
      description = build_issue_description(issue, uploaded)

      created = @client.create_card(
        board_id: board_id,
        title: "#{issue_key} - #{issue.fetch("summary")}",
        description: description,
        created_at: parse_time(issue["created"]),
        last_active_at: parse_time(issue["updated"] || issue["created"])
      )
      assert_success!(created, "create card #{issue_key}")

      card_number = created.body.fetch("number")
      triage_issue_card!(issue, card_number)
      close_issue_card!(issue, card_number)
      assign_issue_card!(issue, card_number)

      @state["cards"][issue.fetch("id")] = {
        "card_number" => card_number,
        "issue_key" => issue_key,
        "uploaded_attachments" => uploaded.transform_values { |entry| slice(entry, "filename", "attachment_html") }
      }
    end

    def triage_issue_card!(issue, card_number)
      project_key = issue.fetch("projectKey")
      status = @scan.dig("statuses", issue["status"])
      return unless status
      return unless OPEN_STATUS_CATEGORIES.include?(status["statuscategory"].to_s)

      column_id = @state.dig("boards", board_state_key_for(project_key), "columns_by_status_id", status.fetch("id"))
      return unless column_id

      response = @client.triage_card(card_number: card_number, column_id: column_id)
      assert_success!(response, "triage #{card_number} to #{status.fetch("name")}")
    end

    def close_issue_card!(issue, card_number)
      status = @scan.dig("statuses", issue["status"])
      closed = CLOSED_STATUS_CATEGORIES.include?(status.to_h["statuscategory"].to_s) || issue["resolution"]
      return unless closed

      response = @client.close_card(card_number: card_number)
      assert_success!(response, "close #{card_number}")
    end

    def assign_issue_card!(issue, card_number)
      assignee = fizzy_user_for_jira_id(issue["assignee"])
      return unless assignee

      response = @client.create_assignment(card_number: card_number, assignee_id: assignee.fetch("id"))
      assert_success!(response, "assign #{card_number} to #{assignee.fetch("email_address") || assignee.fetch("name")}")
    end

    def import_comments!
      puts "Importing comments ..."

      each_record do |type, action|
        next unless type == "Action"
        next unless action["type"] == "comment"
        next if @state.dig("comments", action.fetch("id"), "comment_id")

        issue_id = action["issue"]
        next if @selected_issue_ids_for_run.any? && !@selected_issue_ids_for_run.include?(issue_id)

        card_number = @state.dig("cards", issue_id, "card_number")
        next unless card_number

        import_comment!(action, card_number, issue_id)
        save_state!
      end
    end

    def import_comment!(action, card_number, issue_id)
      issue_key = @state.dig("cards", issue_id, "issue_key") || issue_id
      puts "  comment #{action.fetch("id")} on #{issue_key}"

      comment_body, embedded_uploads = replace_embedded_data_images(
        text: action["body"].to_s,
        scope_key: "#{issue_key}-comment-#{action.fetch("id")}",
        parent_field: "comment"
      )

      body = build_comment_body(action.merge("body" => comment_body), issue_id, embedded_uploads)
      response = @client.create_comment(
        card_number: card_number,
        body: body,
        created_at: parse_time(action["created"])
      )
      assert_success!(response, "create comment #{action.fetch("id")}")

      @state["comments"][action.fetch("id")] = {
        "comment_id" => response.body.fetch("id")
      }
    end

    def upload_issue_attachments(issue)
      attachments = Array(@scan.dig("attachments_by_issue", issue.fetch("id")))
      issue_key = "#{issue.fetch("projectKey")}-#{issue.fetch("number")}"
      uploaded = {}

      attachments.each do |attachment|
        path = attachment_path(issue.fetch("projectKey"), issue_key, attachment.fetch("id"))
        next unless path && File.exist?(path)

        response = @client.upload_attachment_and_build_tag(
          path: path,
          filename: attachment.fetch("filename"),
          content_type: attachment["mimetype"]
        )
        assert_success!(response, "upload attachment #{issue_key}:#{attachment.fetch("filename")}")
        uploaded[attachment.fetch("filename")] = response.body.merge("parentField" => attachment["parentField"])
      end

      uploaded
    end

    def build_issue_description(issue, uploaded_attachments)
      status = @scan.dig("statuses", issue["status"], "name")
      reporter = user_label(issue["reporter"])
      creator = user_label(issue["creator"])
      description = wiki_to_html(issue["description"].to_s, uploaded_attachments)
      metadata = []
      metadata << ["id", "#{issue.fetch("projectKey")}-#{issue.fetch("number")}"]
      metadata << ["status", status] if status
      metadata << ["closed_at", issue["resolutiondate"]] if issue["resolutiondate"]
      metadata << ["created_by", reporter || creator] if reporter || creator
      metadata << ["priority", issue["priority"]] if issue["priority"]

      trailing = issue_level_attachment_gallery(issue["description"].to_s, uploaded_attachments)

      [
        metadata_pre_html(metadata),
        description,
        trailing
      ].reject(&:empty?).join("\n")
    end

    def build_comment_body(action, issue_id, embedded_uploads = {})
      author = user_label(action["author"])
      uploaded = (@state.dig("cards", issue_id, "uploaded_attachments") || {}).merge(embedded_uploads)
      body = wiki_to_html(action["body"].to_s, uploaded)
      meta = []
      meta << ["author", author] if author
      meta << ["created_at", action["created"]] if action["created"]
      [metadata_pre_html(meta), body].reject(&:empty?).join("\n")
    end

    def replace_embedded_data_images(text:, scope_key:, parent_field:)
      uploaded = {}
      index = 0
      rewritten = text.to_s.gsub(DATA_IMAGE_PATTERN) do
        data_url = Regexp.last_match(1)
        mime_type, encoded = data_url.split(",", 2)
        content_type = mime_type.to_s.sub("data:", "").sub(/;base64\z/, "")
        bytes = Base64.decode64(encoded.to_s.gsub(/\s+/, ""))
        filename = "#{scope_key}-inline-image-#{index += 1}.#{file_extension_for_content_type(content_type)}"
        response = @client.upload_attachment_and_build_tag(bytes: bytes, filename: filename, content_type: content_type)
        assert_success!(response, "upload embedded image #{filename}")
        uploaded[filename] = response.body.merge("parentField" => parent_field)
        "[^#{filename}]"
      end

      [rewritten, uploaded]
    end

    def file_extension_for_content_type(content_type)
      {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/svg+xml" => "svg"
      }[content_type] || "bin"
    end

    def metadata_pre_html(pairs)
      lines = pairs.filter_map do |label, value|
        next if value.nil? || value.to_s.strip.empty?
        "#{label}: #{value}"
      end
      return "" if lines.empty?

      "<pre>#{h(lines.join("\n"))}</pre>"
    end

    def issue_level_attachment_gallery(source_text, uploaded_attachments)
      return "" if uploaded_attachments.empty?

      referenced = referenced_attachment_names(source_text)
      extras = uploaded_attachments.values.reject do |entry|
        referenced.include?(entry["filename"]) || entry["parentField"] == "description"
      end
      return "" if extras.empty?

      ["<p><strong>Attachments</strong></p>", *extras.map { |entry| entry["attachment_html"] }].join
    end

    def referenced_attachment_names(text)
      names = Set.new
      INLINE_ATTACHMENT_PATTERNS.each do |pattern|
        text.to_s.scan(pattern) { |match| names << Array(match).first.to_s.strip }
      end
      names
    end

    def wiki_to_html(text, uploaded_attachments)
      html = h(text.to_s)
      html = html.gsub(/\r\n?/, "\n")
      html = extract_code_blocks(html)

      html = html.gsub(/\[~accountid:([^\]]+)\]/) do
        account_id = Regexp.last_match(1)
        label = user_label(account_id) || account_id
        h(label)
      end

      html = replace_bare_user_ids(html)

      html = html.gsub(/\[([^\]|]+)\|((?:https?:\/\/|mailto:)[^\]]+)\]/, '<a href="\2">\1</a>')
      html = html.gsub(/\[((?:https?:\/\/|mailto:)[^\]|]+)\]/, '<a href="\1">\1</a>')
      html = html.gsub(/\{\{([^\n}]+)\}\}/, '<code>\1</code>')
      html = html.gsub(/(^|[\s(])\*([^*\n]+)\*(?=$|[\s).,;:!?])/, '\\1<strong>\\2</strong>')
      html = html.gsub(/^(h[1-6])\.\s+(.+)$/) { "<strong>#{$2}</strong>" }

      uploaded_attachments.each_value do |entry|
        filename = Regexp.escape(entry.fetch("filename"))
        attachment_html = entry.fetch("attachment_html")
        html = html.gsub(/\[\^#{filename}\]/, attachment_html)
        html = html.gsub(/!#{filename}(?:\|[^!]*)?!/, attachment_html)
      end

      blocks = html.split(/\n{2,}/).map do |block|
        lines = block.split("\n")
        if block.start_with?("__CODE_BLOCK_")
          restore_code_blocks(block)
        elsif lines.all? { |line| line.start_with?("# ") }
          "<ul>#{lines.map { |line| "<li>#{line.delete_prefix("# ")}</li>" }.join}</ul>"
        elsif lines.all? { |line| line.start_with?("* ") }
          "<ul>#{lines.map { |line| "<li>#{line.delete_prefix("* ")}</li>" }.join}</ul>"
        elsif lines.all? { |line| line.start_with?("bq. ") }
          "<blockquote>#{lines.map { |line| line.delete_prefix("bq. ") }.join("<br>")}</blockquote>"
        elsif lines.all? { |line| line.start_with?("|") }
          table_html(lines)
        elsif code_like_block?(block)
          "<pre><code>#{restore_code_blocks(block)}</code></pre>"
        else
          "<p>#{restore_code_blocks(lines.join("<br>"))}</p>"
        end
      end

      blocks.join("\n")
    end

    def code_like_block?(block)
      stripped = block.strip
      return false if stripped.empty?
      return true if stripped.match?(/\A[\[{].*[\]}]\z/m)

      lines = stripped.split("\n")
      return false if lines.size < 2

      codeish_lines = lines.count do |line|
        line.match?(/\A\s*[\[{\]()"'].*[\]}\],"']\s*\z/) ||
          line.include?("=>") ||
          line.include?("::") ||
          line.include?(": ")
      end
      codeish_lines >= (lines.size / 2.0)
    end

    def table_html(lines)

      blocks.join("\n")
    end

    def extract_code_blocks(html)
      @code_blocks = []
      html.gsub(/\{code(?::[^}]*)?\}(.*?)\{code\}/m) do
        @code_blocks << "<pre><code>#{Regexp.last_match(1)}</code></pre>"
        "\n\n__CODE_BLOCK_#{@code_blocks.length - 1}__\n\n"
      end
    end

    def restore_code_blocks(html)
      html.gsub(/__CODE_BLOCK_(\d+)__/) { @code_blocks[Regexp.last_match(1).to_i] || Regexp.last_match(0) }
    end

    def table_html(lines)
      rows = lines.map do |line|
        line.split("|")[1..-2].to_a.map(&:strip)
      end
      return "<pre>#{lines.join("\n")}</pre>" if rows.empty?

      header = rows.first
      body = rows.drop(1)
      head_html = "<tr>#{header.map { |cell| "<th>#{cell}</th>" }.join}</tr>"
      body_html = body.map { |row| "<tr>#{row.map { |cell| "<td>#{cell}</td>" }.join}</tr>" }.join
      "<table><thead>#{head_html}</thead><tbody>#{body_html}</tbody></table>"
    end

    def board_description(project)
      parts = []
      parts << "<p><strong>Imported from Jira project #{h(project.fetch("key"))}</strong></p>"
      parts << "<p>#{h(project["description"])} </p>" if project["description"].to_s.strip != ""
      parts.join
    end

    def user_label(account_id)
      return nil if account_id.to_s.strip.empty?

      user = @scan.dig("users", account_id)
      return user["emailAddress"] if user && user["emailAddress"].to_s != ""
      return user["displayName"] if user && user["displayName"].to_s != ""

      account_id
    end

    def replace_bare_user_ids(html)
      @user_replacements ||= @scan.fetch("users").keys
        .sort_by { |account_id| -account_id.length }
        .to_h { |account_id| [account_id, user_label(account_id)] }

      @user_replacements.each do |account_id, label|
        next if label.to_s == "" || label == account_id

        html = html.gsub(Regexp.new("(?<![\\w/:-])#{Regexp.escape(account_id)}(?![\\w-])"), h(label))
      end

      html
    end

    def attachment_path(project_key, issue_key, attachment_id)
      @attachment_path_cache ||= {}
      @attachment_path_cache[[project_key, issue_key, attachment_id]] ||= begin
        pattern = File.join(@options.fetch(:attachments_root), project_key, "*", issue_key, attachment_id.to_s)
        Dir.glob(pattern).first
      end
    end

    def selected_projects
      @selected_projects ||= begin
        explicit = Array(@options[:projects]).map(&:strip).reject(&:empty?)
        inferred = selected_issue_keys.map { |issue_key| issue_key.split("-", 2).first }
        Set.new(explicit + inferred)
      end
    end

    def preload_fizzy_users!
      return @fizzy_users_by_email if defined?(@fizzy_users_by_email)

      users = paginated_collection { |page| @client.list_users(page: page) }

      @fizzy_users_by_email = users.each_with_object({}) do |user, result|
        email = user["email_address"].to_s.strip.downcase
        result[email] = user unless email.empty?
      end
    end

    def fizzy_user_for_jira_id(account_id)
      email = jira_user_email(account_id)
      return nil if email.to_s.empty?

      preload_fizzy_users!
      @fizzy_users_by_email[email.downcase]
    end

    def jira_user_email(account_id)
      user = @scan.dig("users", account_id)
      user && user["emailAddress"].to_s.strip
    end

    def report_user_mapping!
      referenced_ids = selected_jira_user_ids
      missing = referenced_ids.filter_map do |jira_id|
        email = jira_user_email(jira_id)
        next if email.to_s.empty?
        next if fizzy_user_for_jira_id(jira_id)
        [ jira_id, email ]
      end

      puts "Users referenced: #{referenced_ids.size}"
      if missing.empty?
        puts "Missing users: none"
      else
        puts "Missing users (#{missing.size}):"
        missing.sort_by { |(_jira_id, email)| email }.each do |jira_id, email|
          puts "  #{email} (jira: #{jira_id})"
        end
      end
    end

    def selected_jira_user_ids
      selected_issue_ids = Set.new
      each_record do |type, record|
        next unless type == "Issue"
        selected_issue_ids << record.fetch("id") if issue_selected?(record)
      end

      ids = Set.new
      each_record do |type, record|
        case type
        when "Issue"
          next unless selected_issue_ids.include?(record.fetch("id"))
          %w[reporter assignee creator].each do |field|
            value = record[field]
            ids << value if value.to_s.strip != ""
          end
        when "Action"
          next unless record["type"] == "comment"
          next unless selected_issue_ids.include?(record["issue"])
          value = record["author"]
          ids << value if value.to_s.strip != ""
        end
      end
      ids
    end

    def report_column_mapping!
      relevant_project_keys.each do |project_key|
        board_state_key = board_state_key_for(project_key)
        board_id = @state.dig("boards", board_state_key, "board_id")
        puts "Board #{board_name_label(project_key)} => #{board_id}"

        Array(@scan.dig("status_ids_by_project", project_key)).uniq.each do |status_id|
          status = @scan.dig("statuses", status_id)
          next unless status
          next unless OPEN_STATUS_CATEGORIES.include?(status["statuscategory"].to_s)

          column_id = @state.dig("boards", board_state_key, "columns_by_status_id", status_id)
          puts "  #{status.fetch("name")} => #{column_id}"
        end
      end
    end

    def board_name_label(project_key)
      custom = @options[:board_name].to_s.strip
      custom.empty? ? project_key : custom
    end

    def find_board_by_name(name)
      paginated_collection { |page| @client.list_boards(page: page) }
        .find { |board| board["name"].to_s == name.to_s }
    end

    def paginated_collection
      records = []
      page = 1
      loop do
        response = yield(page)
        assert_success!(response, "list page #{page}")
        batch = Array(response.body)
        records.concat(batch)
        break if batch.empty?
        page += 1
      end
      records
    end

    def selected_issue_keys
      @selected_issue_keys ||= Array(@options[:ids]).map(&:strip).reject(&:empty?).to_set
    end

    def relevant_project_keys
      @relevant_project_keys ||= begin
        keys = selected_projects.any? ? selected_projects : @scan.fetch("projects").values.map { |project| project.fetch("key") }.to_set
        keys.select { |project_key| selected_issue_keys.empty? || selected_issue_keys.any? { |issue_key| issue_key.start_with?("#{project_key}-") } }.to_set
      end
    end

    def issue_selected?(issue)
      return false if selected_projects.any? && !selected_projects.include?(issue["projectKey"])

      issue_key = "#{issue.fetch("projectKey")}-#{issue.fetch("number")}"
      selected_issue_keys.empty? || selected_issue_keys.include?(issue_key)
    end

    def import_limit
      @options[:limit]
    end

    def board_state_key_for(project_key)
      custom = @options[:board_name].to_s.strip
      custom.empty? ? project_key : "board:#{custom}"
    end

    def board_name_for(project)
      custom = @options[:board_name].to_s.strip
      return custom unless custom.empty?

      "#{project.fetch("key")} - #{project.fetch("name")}"
    end

    def unique_name(name, used_names)
      candidate = name.to_s.strip
      candidate = "Unnamed" if candidate.empty?
      return used_names << candidate && candidate unless used_names.include?(candidate)

      index = 2
      loop do
        alt = "#{candidate} (#{index})"
        unless used_names.include?(alt)
          used_names << alt
          return alt
        end
        index += 1
      end
    end

    def assert_success!(response, label)
      return if response.success?

      raise "#{label} failed: #{response.status} #{response.message.inspect}"
    end

    def parse_time(value)
      return nil if value.to_s.strip.empty?
      Time.parse(value)
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def slice(hash, *keys)
      keys.each_with_object({}) { |key, result| result[key] = hash[key] if hash.key?(key) }
    end

    def each_record(&block)
      JiraEntityReader.new(@options.fetch(:xml_path)).each(&block)
    end
end

class JiraEntityReader
  LEAF_TAGS = %w[
    Project Status IssueType User Issue FileAttachment Action
  ].freeze
  TEXT_CHILDREN = %w[description body].freeze

  def initialize(path)
    @path = path
  end

  def each
    parser = REXML::Parsers::PullParser.new(File.open(@path, "r:UTF-8", invalid: :replace, undef: :replace))
    current = nil
    current_text_child = nil

    while parser.has_next?
      event = parser.pull

      case event.event_type
      when :start_element
        name = event[0]
        attrs = attrs_hash(event[1])

        if LEAF_TAGS.include?(name)
          current = { "__type__" => name }.merge(attrs)
        elsif current && TEXT_CHILDREN.include?(name)
          current_text_child = name
          current[current_text_child] = +""
        end
      when :text, :cdata
        next unless current && current_text_child
        current[current_text_child] << event[0].to_s
      when :end_element
        name = event[0]

        if current && current_text_child == name
          current_text_child = nil
        elsif current && current["__type__"] == name
          type = current.delete("__type__")
          yield type, current
          current = nil
        end
      end
    end
  ensure
    parser&.source&.close if parser&.source.respond_to?(:close)
  end

  private
    def attrs_hash(attrs)
      attrs.to_h.transform_values { |value| CGI.unescapeHTML(value.to_s) }
    end
end

options = {
  state_path: JiraXmlToFizzy::DEFAULT_STATE_PATH
}

OptionParser.new do |parser|
  parser.banner = <<~TEXT
    Usage:
      ruby script/jira_xml_to_fizzy.rb \
        --xml data/jira-export/entities.xml \
        --attachments data/jira-export/data/attachments \
        --base-url http://app.fizzy.localhost:3006 \
        --account-slug 1234567 \
        --token YOUR_TOKEN
  TEXT

  parser.on("--xml PATH", "Path to Jira entities.xml") { |value| options[:xml_path] = value }
  parser.on("--attachments PATH", "Path to Jira attachment root") { |value| options[:attachments_root] = value }
  parser.on("--base-url URL", "Fizzy base URL") { |value| options[:base_url] = value }
  parser.on("--account-slug SLUG", "Fizzy account slug") { |value| options[:account_slug] = value }
  parser.on("--token TOKEN", "Fizzy bearer token") { |value| options[:token] = value }
  parser.on("--state PATH", "State JSON path (default: #{JiraXmlToFizzy::DEFAULT_STATE_PATH})") { |value| options[:state_path] = value }
  parser.on("--projects x,y,z", Array, "Only import these Jira project keys") { |value| options[:projects] = value }
  parser.on("--board NAME", "Import selected issues into this board name") { |value| options[:board_name] = value }
  parser.on("--limit N", Integer, "Import at most N matching issues") { |value| options[:limit] = value }
  parser.on("--ids KEY1,KEY2", Array, "Only import these Jira issue keys, e.g. MAN-754,MAN-755") { |value| options[:ids] = value }
  parser.on("--preflight", "Check boards/users/columns and exit") { options[:preflight] = true }
end.parse!

required = %i[xml_path attachments_root base_url account_slug token]
missing = required.select { |key| options[key].to_s.strip.empty? }
abort("Missing required options: #{missing.join(', ')}") if missing.any?
abort("--limit must be greater than 0") if options.key?(:limit) && options[:limit].to_i <= 0

JiraXmlToFizzy.new(options).run
