require 'puppet'
require 'net/http'
require 'uri'
require 'multi_json'
require 'base64'
require 'r10k/module_loader/puppetfile'

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

    def initialize
      @puppet_version = Puppet.version
      @missing_vendored = []

      # get the entire file tree of the puppetlabs/puppet-agent repository
      puppet_agent_tree = query_or_cache("https://api.github.com/repos/puppetlabs/puppet-agent/git/trees/#{@puppet_version}", { :recursive => true }, 'files.json')
      # get only the module-puppetlabs-<something>_core.json component files
      vendored_components =  puppet_agent_tree['tree'].select { |file| /configs\/components\/module-puppetlabs-\w+\.json/.match(file['path']) }
      # get the contents of each component file
      @vendored_references = vendored_components.map do |component|
        mod_slug = component['path'].match(/.*(puppetlabs-\w+).json$/)[1]
        mod_name = mod_slug.match(/puppetlabs-(\w+)/)[1]
        encoded_info = query_or_cache(component['url'], nil, "#{mod_name}.json")
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
          @missing_vendored << {mod_slug => {git: mod['url'], ref: mod['ref']}}
          puts "#{mod_name} found to be missing"
        else
          puts "#{mod_name} existed in puppetfile. using specified version"
        end
      end
    end

    # return json from a query whom caches, or from the cache to avoid spamming github
    def query_or_cache(url, params, filepath)
      if File.exist? filepath
        json = read_json_dump(filepath)
      else
        json = github_get(url, params)
        write_json_dump(filepath, json)
      end
      json
    end

    # given a github url and optional query parameters, return the parsed json body
    def github_get(url, params)
      uri = URI(url)
      headers = {Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}
      uri.query = URI.encode_www_form(params) if params
      response = Net::HTTP.get_response(uri, headers)
      MultiJson.load(response.body) if response.is_a?(Net::HTTPSuccess)
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
