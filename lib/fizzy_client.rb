require "net/http"
require "uri"
require "json"
require "digest/md5"
require "base64"
require "stringio"
require "time"

module Fizzy
  class Response
    attr_reader :status, :headers, :body, :raw_body

    def initialize(status:, headers: {}, raw_body: nil, body: :__parse__, message: nil)
      @status = status.to_i
      @headers = self.class.normalize_headers(headers)
      @raw_body = raw_body
      @body = body == :__parse__ ? parse_body(raw_body) : body
      @message = message
    end

    def self.from_http(http_response)
      new(status: http_response.code.to_i, headers: http_response.to_hash, raw_body: http_response.body)
    end

    def self.synthetic(error:, message:, status: 0, headers: {})
      new(status: status, headers: headers, body: { "error" => error, "message" => message }, raw_body: nil, message: message)
    end

    def success?
      (200..299).cover?(status)
    end

    def error?
      !success?
    end

    def json?
      body.is_a?(Hash) || body.is_a?(Array)
    end

    def message
      return @message if @message
      return body["message"] if body.is_a?(Hash) && body["message"]
      return raw_body if raw_body.is_a?(String) && !raw_body.empty?
      return "HTTP #{status}" if status.positive?

      nil
    end

    def self.normalize_headers(headers)
      headers.each_with_object({}) do |(key, value), result|
        result[canonical_header(key)] = value.is_a?(Array) ? value.join(", ") : value.to_s
      end
    end

    def self.canonical_header(key)
      key.to_s.split("-").map { |part| part[0] ? part[0].upcase + part[1..].downcase : part }.join("-")
    end

    private
      def parse_body(value)
        return nil if value.nil? || value == ""

        if json_content_type? || looks_like_json?(value)
          JSON.parse(value)
        else
          value
        end
      rescue JSON::ParserError
        value
      end

      def json_content_type?
        headers.fetch("Content-Type", "").include?("json")
      end

      def looks_like_json?(value)
        stripped = value.lstrip
        stripped.start_with?("{", "[")
      end
  end

  class Request
    NETWORK_ERRORS = [
      SocketError,
      SystemCallError,
      IOError,
      Timeout::Error,
      Net::OpenTimeout,
      Net::ReadTimeout,
      EOFError,
      OpenSSL::SSL::SSLError,
      URI::InvalidURIError
    ].freeze

    def initialize(base_url:, bearer_token: nil, open_timeout: 10, read_timeout: 60, write_timeout: 60, user_agent: "fizzy-client/1.0")
      @base_url = base_url
      @bearer_token = bearer_token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @user_agent = user_agent
    end

    def call(method:, path:, query: nil, headers: nil, body: nil, base_url: nil, bearer_token: :default)
      uri = build_uri(base_url || @base_url, path, query)
      request = build_http_request(method, uri, headers || {}, body, bearer_token)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)

      Response.from_http(http.request(request))
    rescue *NETWORK_ERRORS => error
      Response.synthetic(error: "connection_failed", message: error.message)
    end

    private
      def build_uri(base_url, path, query)
        uri = path.to_s.start_with?("http://", "https://") ? URI(path.to_s) : URI.join(ensure_trailing_slash(base_url), path.to_s.sub(%r{\A/}, ""))
        encoded_query = encode_query(query)
        query_parts = [ uri.query, encoded_query ].compact.reject(&:empty?)
        uri.query = query_parts.empty? ? nil : query_parts.join("&")
        uri
      end

      def ensure_trailing_slash(url)
        url.end_with?("/") ? url : "#{url}/"
      end

      def build_http_request(method, uri, headers, body, bearer_token)
        request_class = Net::HTTP.const_get(method.to_s.capitalize)
        request = request_class.new(uri)

        final_headers = default_headers(bearer_token).merge(headers.transform_keys(&:to_s))
        final_headers.each { |key, value| request[key] = value }

        if body.is_a?(Hash)
          request["Content-Type"] ||= "application/json"
          request.body = JSON.generate(serialize_value(body))
        elsif body
          request.body = body
        end

        request
      end

      def default_headers(bearer_token)
        token = bearer_token == :default ? @bearer_token : bearer_token
        headers = { "Accept" => "application/json", "User-Agent" => @user_agent }
        headers["Authorization"] = "Bearer #{token}" if token
        headers
      end

      def encode_query(query)
        return nil if query.nil? || query.empty?

        parts = []
        serialize_value(query).each do |key, value|
          if value.is_a?(Array)
            value.each { |entry| parts << ["#{key}[]", entry] }
          else
            parts << [key, value]
          end
        end
        URI.encode_www_form(parts)
      end

      def serialize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, inner), result|
            next if inner.nil?
            result[key.to_s] = serialize_value(inner)
          end
        when Array
          value.compact.map { |inner| serialize_value(inner) }
        when Time, DateTime
          value.iso8601
        else
          value
        end
      end
  end

  class Client
    attr_reader :base_url, :bearer_token, :account_slug

    def initialize(base_url:, bearer_token:, account_slug: nil, open_timeout: 10, read_timeout: 60, write_timeout: 60, user_agent: "fizzy-client/1.0")
      @base_url = base_url
      @bearer_token = bearer_token
      @account_slug = account_slug
      @request = Request.new(base_url: base_url, bearer_token: bearer_token, open_timeout: open_timeout, read_timeout: read_timeout, write_timeout: write_timeout, user_agent: user_agent)
    end

    def request(method:, path:, params: nil, query: nil, headers: nil, body: nil)
      request_body = body || params
      @request.call(method: method, path: path, query: query, headers: headers, body: request_body)
    end

    def get_identity
      request(method: :get, path: "/my/identity")
    end

    def list_boards(page: nil)
      account_request(:get, "/boards", query: compact(page: page))
    end

    def get_board(board_id:)
      account_request(:get, "/boards/#{board_id}")
    end

    def create_board(name:, all_access: nil, auto_postpone_period_in_days: nil, public_description: nil)
      account_request(:post, "/boards", body: nested(:board, compact(name: name, all_access: all_access, auto_postpone_period_in_days: auto_postpone_period_in_days, public_description: public_description)))
    end

    def update_board(board_id:, name: nil, all_access: nil, auto_postpone_period_in_days: nil, public_description: nil)
      account_request(:patch, "/boards/#{board_id}", body: nested(:board, compact(name: name, all_access: all_access, auto_postpone_period_in_days: auto_postpone_period_in_days, public_description: public_description)))
    end

    def delete_board(board_id:)
      account_request(:delete, "/boards/#{board_id}")
    end

    def list_columns(board_id:)
      account_request(:get, "/boards/#{board_id}/columns")
    end

    def get_column(board_id:, column_id:)
      account_request(:get, "/boards/#{board_id}/columns/#{column_id}")
    end

    def create_column(board_id:, name:, color: nil)
      account_request(:post, "/boards/#{board_id}/columns", body: nested(:column, compact(name: name, color: color)))
    end

    def update_column(board_id:, column_id:, name: nil, color: nil)
      account_request(:patch, "/boards/#{board_id}/columns/#{column_id}", body: nested(:column, compact(name: name, color: color)))
    end

    def delete_column(board_id:, column_id:)
      account_request(:delete, "/boards/#{board_id}/columns/#{column_id}")
    end

    def list_cards(**query)
      account_request(:get, "/cards", query: compact(query))
    end

    def get_card(card_number:)
      account_request(:get, "/cards/#{card_number}")
    end

    def create_card(board_id:, title:, description: nil, created_at: nil, last_active_at: nil)
      account_request(:post, "/boards/#{board_id}/cards", body: nested(:card, compact(title: title, description: description, created_at: created_at, last_active_at: last_active_at)))
    end

    def update_card(card_number:, title: nil, description: nil, created_at: nil, last_active_at: nil)
      account_request(:patch, "/cards/#{card_number}", body: nested(:card, compact(title: title, description: description, created_at: created_at, last_active_at: last_active_at)))
    end

    def delete_card(card_number:)
      account_request(:delete, "/cards/#{card_number}")
    end

    def move_card_to_board(card_number:, board_id:)
      account_request(:patch, "/cards/#{card_number}/board", body: { board_id: board_id })
    end

    def triage_card(card_number:, column_id:)
      account_request(:post, "/cards/#{card_number}/triage", body: { column_id: column_id })
    end

    def untriage_card(card_number:)
      account_request(:delete, "/cards/#{card_number}/triage")
    end

    def close_card(card_number:)
      account_request(:post, "/cards/#{card_number}/closure")
    end

    def reopen_card(card_number:)
      account_request(:delete, "/cards/#{card_number}/closure")
    end

    def move_card_to_not_now(card_number:)
      account_request(:post, "/cards/#{card_number}/not_now")
    end

    def list_comments(card_number:, page: nil)
      account_request(:get, "/cards/#{card_number}/comments", query: compact(page: page))
    end

    def get_comment(card_number:, comment_id:)
      account_request(:get, "/cards/#{card_number}/comments/#{comment_id}")
    end

    def create_comment(card_number:, body:, created_at: nil)
      account_request(:post, "/cards/#{card_number}/comments", body: nested(:comment, compact(body: body, created_at: created_at)))
    end

    def create_assignment(card_number:, assignee_id:)
      account_request(:post, "/cards/#{card_number}/assignments", body: compact(assignee_id: assignee_id))
    end

    def update_comment(card_number:, comment_id:, body:, created_at: nil)
      account_request(:patch, "/cards/#{card_number}/comments/#{comment_id}", body: nested(:comment, compact(body: body, created_at: created_at)))
    end

    def delete_comment(card_number:, comment_id:)
      account_request(:delete, "/cards/#{card_number}/comments/#{comment_id}")
    end

    def list_users(page: nil)
      account_request(:get, "/users", query: compact(page: page))
    end

    def get_user(user_id:)
      account_request(:get, "/users/#{user_id}")
    end

    def update_user(user_id:, name: nil)
      account_request(:patch, "/users/#{user_id}", body: nested(:user, compact(name: name)))
    end

    def delete_user(user_id:)
      account_request(:delete, "/users/#{user_id}")
    end

    def create_direct_upload(filename:, byte_size:, checksum:, content_type:)
      account_request(:post, "/rails/active_storage/direct_uploads", body: nested(:blob, compact(filename: filename, byte_size: byte_size, checksum: checksum, content_type: content_type)))
    end

    def upload_direct_file(url:, headers:, io: nil, path: nil, bytes: nil)
      payload = read_upload_source(io: io, path: path, bytes: bytes)
      return payload if payload.is_a?(Response)

      @request.call(method: :put, path: url, headers: headers, body: payload[:bytes], bearer_token: nil)
    end

    def build_rich_text_attachment(signed_id:)
      %(<action-text-attachment sgid="#{signed_id}"></action-text-attachment>)
    end

    def upload_attachment_and_build_tag(filename: nil, content_type: nil, io: nil, path: nil, bytes: nil)
      payload = read_upload_source(io: io, path: path, bytes: bytes, filename: filename, content_type: content_type)
      return payload if payload.is_a?(Response)

      create = create_direct_upload(filename: payload[:filename], byte_size: payload[:byte_size], checksum: payload[:checksum], content_type: payload[:content_type])
      return stage_error("direct_upload_create_failed", create) if create.error?

      signed_id = create.body["signed_id"]
      attachment_sgid = create.body["attachable_sgid"] || signed_id
      direct_upload = create.body["direct_upload"] || {}
      upload = upload_direct_file(url: direct_upload["url"], headers: direct_upload["headers"] || {}, bytes: payload[:bytes])
      return stage_error("direct_file_upload_failed", upload) if upload.error?

      Response.new(status: 200, body: {
        "signed_id" => signed_id,
        "attachable_sgid" => attachment_sgid,
        "attachment_html" => build_rich_text_attachment(signed_id: attachment_sgid),
        "filename" => payload[:filename],
        "content_type" => payload[:content_type],
        "byte_size" => payload[:byte_size]
      })
    end

    def append_attachments_to_html(html, attachments:)
      tags = Array(attachments).filter_map do |attachment|
        case attachment
        when String
          attachment.include?("<action-text-attachment") ? attachment : build_rich_text_attachment(signed_id: attachment)
        when Hash
          if attachment["attachment_html"] || attachment[:attachment_html]
            attachment["attachment_html"] || attachment[:attachment_html]
          elsif attachment["attachable_sgid"] || attachment[:attachable_sgid] || attachment["signed_id"] || attachment[:signed_id]
            build_rich_text_attachment(signed_id: attachment["attachable_sgid"] || attachment[:attachable_sgid] || attachment["signed_id"] || attachment[:signed_id])
          end
        end
      end
      [ html.to_s, *tags ].join
    end

    private
      def account_request(method, path, query: nil, headers: nil, body: nil)
        return missing_account_slug_response unless account_slug

        request(method: method, path: "/#{account_slug}#{path}", query: query, headers: headers, body: body)
      end

      def missing_account_slug_response
        Response.synthetic(error: "missing_account_slug", message: "This endpoint requires a configured account slug")
      end

      def nested(key, value)
        { key => value }
      end

      def compact(hash)
        hash.each_with_object({}) { |(key, value), result| result[key] = value unless value.nil? }
      end

      def read_upload_source(io: nil, path: nil, bytes: nil, filename: nil, content_type: nil)
        if bytes
          raw_bytes = bytes.is_a?(String) ? bytes.b : bytes.to_s.b
          inferred_filename = filename || "upload.bin"
        elsif path
          return Response.synthetic(error: "file_not_found", message: "Upload file not found: #{path}") unless File.exist?(path)
          raw_bytes = File.binread(path)
          inferred_filename = filename || File.basename(path)
          content_type ||= mime_type_for(path)
        elsif io
          io.rewind if io.respond_to?(:rewind)
          raw_bytes = io.read.to_s.b
          inferred_filename = filename || (io.respond_to?(:path) && io.path ? File.basename(io.path) : "upload.bin")
          content_type ||= mime_type_for(io.path) if io.respond_to?(:path) && io.path
        else
          return Response.synthetic(error: "missing_upload_source", message: "Provide one of path:, io:, or bytes:")
        end

        content_type ||= "application/octet-stream"

        {
          bytes: raw_bytes,
          byte_size: raw_bytes.bytesize,
          checksum: Base64.strict_encode64(Digest::MD5.digest(raw_bytes)),
          filename: inferred_filename,
          content_type: content_type
        }
      end

      def stage_error(stage, response)
        Response.new(status: response.status, headers: response.headers, raw_body: response.raw_body, body: {
          "error" => stage,
          "message" => response.message,
          "response" => response.body
        })
      end

      def mime_type_for(path)
        ext = File.extname(path.to_s).downcase
        {
          ".png" => "image/png",
          ".jpg" => "image/jpeg",
          ".jpeg" => "image/jpeg",
          ".gif" => "image/gif",
          ".svg" => "image/svg+xml",
          ".webp" => "image/webp",
          ".txt" => "text/plain",
          ".pdf" => "application/pdf"
        }[ext]
      end
  end
end

FizzyClient = Fizzy unless defined?(FizzyClient)
