require 'puppet'
require 'net/http'
require 'uri'
require 'multi_json'
require 'base64'
require 'r10k/module_loader/puppetfile'
require 'onceover/logger'

### operations
#
# 1. resolve all the component json files in the puppet-agent repo for vendored modules
# 2. parse each json file and determine vendored modules repo + ref
#
###

## Example
#
# vm = Onceover::VendoredModules.new
# puts vm.vendored_references
# puppetfile = R10K::ModuleLoader::Puppetfile.new(basedir: '.')
# vm.puppetfile_missing_vendored(puppetfile)
# puts vm.missing_vendored.inspect

class Onceover
  class VendoredModules

    attr_reader :vendored_references, :missing_vendored

    def initialize(repo = Onceover::Controlrepo.new)
      @puppet_version = Puppet.version
      @missing_vendored = []

      @vend_tmpdir = File.join(repo.tempdir, 'vendored_modules')
      unless File.directory?(@vend_tmpdir)
        logger.debug "Creating #{@vend_tmpdir}"
        FileUtils.mkdir_p(@vend_tmpdir)
      end
      # get the entire file tree of the puppetlabs/puppet-agent repository
      puppet_agent_tree = query_or_cache("https://api.github.com/repos/puppetlabs/puppet-agent/git/trees/#{@puppet_version}", { :recursive => true }, File.join(@vend_tmpdir, "puppet_agent_tree-#{@puppet_version}.json"))
      # get only the module-puppetlabs-<something>_core.json component files
      vendored_components =  puppet_agent_tree['tree'].select { |file| /configs\/components\/module-puppetlabs-\w+\.json/.match(file['path']) }
      # get the contents of each component file
      @vendored_references = vendored_components.map do |component|
        mod_slug = component['path'].match(/.*(puppetlabs-\w+).json$/)[1]
        mod_name = mod_slug.match(/puppetlabs-(\w+)/)[1]
        encoded_info = query_or_cache(component['url'], nil, File.join(@vend_tmpdir, "puppet-#{@puppet_version}-#{mod_name}.json"))
        MultiJson.load(Base64.decode64(encoded_info['content']))
      end
    end

    # currently expects to be passed a R10K::Puppetfile object.
    # ex: R10K::ModuleLoader::Puppetfile.new(basedir: '.')
    def puppetfile_missing_vendored(puppetfile)
      puppetfile.load
      @vendored_references.each do |mod|
        # extract name and slug from url
        mod_slug = mod['url'].match(/.*(puppetlabs-\w+)\.git/)[1]
        mod_name = mod_slug.match(/^puppetlabs-(\w+)$/)[1]
        # array of modules whos names match
        existing = puppetfile.modules.select { |e_mod| e_mod.name == mod_name }
        if existing.empty?
          # Change url to https instead of ssh to avoid 'Host key verification failed' errors
          # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
          url = mod['url'].gsub('git@github.com:', 'https://github.com/')
          @missing_vendored << {mod_slug => {git: url, ref: mod['ref']}}
          logger.debug "#{mod_name} found to be missing in Puppetfile"
        else
          logger.debug "#{mod_name} found in Puppetfile. Using the specified version"
        end
      end
    end

    # return json from a query whom caches, or from the cache to avoid spamming github
    def query_or_cache(url, params, filepath)
      if File.exist? filepath
        logger.debug "Using cache: #{filepath}"
        json = read_json_dump(filepath)
      else
        logger.debug "Making GET request to: #{url}"
        json = github_get(url, params)
        logger.debug "Caching response to: #{filepath}"
        write_json_dump(filepath, json)
      end
      json
    end

    # given a github url and optional query parameters, return the parsed json body
    def github_get(url, params)
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(params) if params
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      request = Net::HTTP::Get.new(uri.request_uri)
      request['Accept'] = 'application/vnd.github+json'
      request['X-GitHub-Api-Version'] = '2022-11-28'
      response = http.request(request)

      case response
      when Net::HTTPOK # 200
        MultiJson.load(response.body)
      else
        # Expose the ratelimit response headers
        # https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2022-11-28#checking-the-status-of-your-rate-limit
        ratelimit_headers = response.to_hash.select { |k, v| k =~ /x-ratelimit.*/ }
        raise "#{response.code} #{response.message} #{ratelimit_headers}"
      end
    end

    # returns parsed json of file
    def read_json_dump(filepath)
      MultiJson.load(File.read(filepath))
    end

    # writes json to a file
    def write_json_dump(filepath, json_data)
      File.write(filepath, MultiJson.dump(json_data))
    end
  end
end
