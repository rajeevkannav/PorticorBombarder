require 'hashie'
require 'faraday_middleware'
require 'securerandom'

module PorticorBombarder

  class Client

    @@porticor_require_options = %w(api_key api_secret api_url)

    attr_accessor *@@porticor_require_options

    def initialize
      @@porticor_require_options.each do |r_port_option|
        raise InvalidOptions.new("You must specify your Porticor #{r_port_option}.") unless PORTICOR_CONFIGURATION[r_port_option].present?
        public_send("#{r_port_option}=", PORTICOR_CONFIGURATION[r_port_option])
      end
    end

    def fetch_encryption_key(name, source = 'cache')
      begin
        return case source
                 when 'cache'
                   get_encryption_key_via_cache(name)
                 when 'file_system'
                   get_encryption_key_via_file_system(name)
                 when 'appliance'
                   get_encryption_key(name)
                 else
                   raise Error.new('Invalid encryption_key source.')
               end
      rescue KeyPairCacheNotAvailable => e
        PorticorBombarder::PorticorLogger.logger.warn e.message
        fetch_encryption_key(name, 'file_system')
      rescue KeyPairFileSystemNotAvailable => e
        PorticorBombarder::PorticorLogger.logger.warn e.message
        fetch_encryption_key(name, 'appliance')
      rescue Exception => e
        PorticorBombarder::PorticorLogger.logger.warn e.message
        nil
      end
    end

    def get_encryption_key_via_cache(name)
      raise KeyPairCacheNotAvailable.new('Requested key_pair not available in Cache.')
    end

    def get_encryption_key_via_file_system(name)
      begin
        File.read(File.join(PORTICOR_STORAGE_PATH, "#{name}.pem"))
      rescue
        raise KeyPairFileSystemNotAvailable.new('Requested key_pair not available in FileSystem.')
      end
    end

    def get_encryption_key(name)
      response = get("/api/protected_items/#{URI.escape(name)}", api_cred: temp_cred)
      if success?(response)
        response.body.item
      else
        nil
      end
    end

    def find_or_create_encryption_key(name, algorithm = 'RSA2048', export = true)
      begin
        create_encryption_key(name, algorithm, export)
      rescue DuplicateItemError
        fetch_encryption_key(name)
      rescue Exception => e
        PorticorBombarder::PorticorLogger.logger.warn e.message
        nil
      end
    end

    def create_encryption_key(name, algorithm = 'RSA2048', export = true)
      response = post("/api/protected_items/#{URI.escape(name)}", algorithm: algorithm, exportable: export, api_cred: temp_cred)
      if success?(response)
        response.body.item
      else
        case response.body['error_code']
          when 'CreateDuplicate'
            raise DuplicateItemError.new response.body['error']
          else
            raise Error.new response.body['error_code']
        end
      end
    end


    def get_time
      response = get('/api/creds/get_time')
      if success?(response)
        response.body.time
      else
        nil
      end
    end

    def temp_cred
      @@temp_cred ||= begin
        time = get_time
        nonce = generate_nonce
        sig = sign_cred_request(nonce, time)
        response = get('/api/creds/get_temporary_credential',
                       api_key_id: api_key,
                       time: time,
                       nonce: nonce,
                       api_signature: sig)
        if success?(response)
          response.body.credential
        else
          nil
        end
      end
    end

    private

    # return true for successful response code
    def success?(response)
      response.success? && response.body['error'].empty?
    end

    # return some random string
    def generate_nonce
      SecureRandom.hex(8)
    end

    # Computing the Signature for get_temporary_credential Currently it works for API V1
    # VERSION - 2 will be done sometime later.
    def sign_cred_request(nonce, time)
      str_to_sign = "get_temporary_credential?api_key_id=#{api_key}&nonce=#{nonce}&time=#{time}"
      digest = OpenSSL::Digest.new('sha256')
      sig = OpenSSL::HMAC.hexdigest(digest, api_secret, str_to_sign)
      return 'hmac-sha256:' + sig
    end

    # returns Porticor's client connection
    def connection
      Faraday.new(url: api_url) do |conn|
        conn.request :json
        conn.use Faraday::Response::Mashify
        conn.response :json, content_type: /\bjson$/
        conn.response :raise_error
        conn.adapter Faraday.default_adapter
      end
    end

    # Porticor's API GET request
    def get(path, options = {})
      connection.get(path, options)
    end

    # Porticor's API requires PUT request for creating an encryption_key
    def post(path, options = {})
      connection.put(path) do |request|
        request.params = options
      end
    end

  end
end


