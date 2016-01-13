require 'base64'
require 'config/key_manager'
require 'faraday'
require 'haml'
require 'json'
require 'tx_logger'
require 'sinatra'
require 'sinatra/reloader'
require 'strava/l10n/github_repo'
require 'strava/l10n/transifex_project'
require 'pry'

module L10n

  class Application < Sinatra::Base

    use Rack::Auth::Basic, 'Restricted Area' do |username, password|
      username == 'foo' and password == 'bar'
    end

    configure :development do
      register Sinatra::Reloader
    end

    def initialize(app = nil)
      super(app)
    end

    get '/health_check' do
      200
    end

  end

  class Hooks < Sinatra::Base
    # Hooks are unprotected endpoints used for data integration between GitHub and
    # Transifex. They live under the /hooks namespace (see config.ru)

    configure :production do
      set :logging, nil
      logger = Txgh::TxLogger.logger
      set :logger, logger
    end

    configure :development , :test do
      register Sinatra::Reloader
      set :logging, nil
      logger = Txgh::TxLogger.logger
      set :logger, logger
    end

    def initialize(app = nil)
      super(app)
    end


    post '/transifex' do
      settings.logger.info "Processing request at /hooks/transifex"
      settings.logger.info request.inspect
      transifex_project = Strava::L10n::TransifexProject.new(request['project'])

      resource = {
        name: request['resource'],
        branch: 'master'
      }

      if request['resource'].include? Strava::L10n::TxResource.branch_separator
        resource[:name], resource[:branch] = request['resource'].split Strava::L10n::TxResource.branch_separator
      end

      tx_resource = transifex_project.resource(resource[:name])
      settings.logger.info resource[:name]

      # Do not update the source
      unless request['language'] == tx_resource.source_lang
        settings.logger.info "request language matches resource"
        translation = transifex_project.api.download(tx_resource, request['language'], resource[:branch])

        if tx_resource.lang_map(request['language']) != request['language']
          settings.logger.info "request language is in lang_map and is not in request"
          translation_path = tx_resource.translation_path(tx_resource.lang_map(request['language']))
        else
          settings.logger.info "request language is in lang_map and is in request or is nil"
          translation_path = tx_resource.translation_path(transifex_project.lang_map(request['language']))
        end

        github_escaped_branch = transifex_project.github_repo.config.fetch 'branch', resource[:branch]
        github_branch = transifex_project.api.unescape_branch(github_escaped_branch)
        github_commit_branch = 'heads/'+github_branch

        settings.logger.info "make github commit for branch: " + github_commit_branch
        transifex_project.github_repo.api.commit(
          transifex_project.github_repo.name,
          github_commit_branch,
          translation_path,
          translation
        )
      end
    end

    post '/github' do
      settings.logger.info "Processing request at /hooks/github"

      if params[:payload] != nil
        settings.logger.info "processing payload from form"
        hook_data = JSON.parse(params[:payload], symbolize_names: true)
      else
        settings.logger.info "processing payload from request.body"
        hook_data = JSON.parse(request.body.read, symbolize_names: true)
      end

      github_repo_branch = "#{hook_data[:ref]}"
      github_branch = github_repo_branch.match(/refs\/heads\/([a-zA-z0-9\-\_\/]+)/).captures.first

      github_repo_name = "#{hook_data[:repository][:owner][:name]}/#{hook_data[:repository][:name]}"
      github_repo = Strava::L10n::GitHubRepo.new(github_repo_name)

      transifex_project = github_repo.transifex_project

      # Check if the branch in the hook data is the configured branch we want
      settings.logger.info "request github branch:" + github_branch

      # Build an index of known Tx resources, by source file
      tx_resources = {}
      transifex_project.resources.each do |resource|
        settings.logger.info "processing resource"
        tx_resources[resource.source_file] = resource
      end

      github_api = github_repo.api

      updated_resources = {}
      updated_resource_translations = {}

      # We need to handle a new branch commit and a merge commit differently
      # For those cases we want to update all resources available, including source
      # and translation languages.
      # A new branch commit can be identified if there are no commits.
      # A merge commit can be identified if the head commit parents are more than 1
      is_new_branch_commit = hook_data[:commits].empty?
      is_merge_commit = (!hook_data[:head_commit].empty?) && (github_api.get_commit(github_repo_name, hook_data[:head_commit][:id])[:parents].length > 1)

      binding.pry

      if is_new_branch_commit or is_merge_commit
        tree_sha = github_api.get_commit(github_repo_name, hook_data[:head_commit][:id])[:commit][:tree][:sha]
        tree = github_api.tree github_repo_name, tree_sha

        tx_resources.each do |source_file, tx_resource|

          translation_path_pattern = tx_resource.translation_path(Strava::L10n::TxResource.locale_regex)

          tree[:tree].each do |file|
            settings.logger.info "new branch/ merge :: process each tree entry:" + file[:path]

            is_translation_file = file[:path].match(/#{translation_path_pattern}/) != nil
            is_source_file = file[:path] == source_file

            binding.pry

            if is_source_file
              updated_resources[tx_resource] = hook_data[:head_commit][:id]
            end
            if is_translation_file
              lang = file[:path].match(/#{translation_path_pattern}/)[1]
              if updated_resource_translations[tx_resource] == nil
                updated_resource_translations[tx_resource] = {}
              updated_resource_translations[tx_resource][lang] = hook_data[:head_commit][:id]
            end
          end
        end
      else
        # Find the updated resources and maps the most recent commit in which
        # each was modified
        hook_data[:commits].each do |commit|
          settings.logger.info "processing commit"
          commit[:modified].each do |modified|
            settings.logger.info "processing modified file:"+modified

            updated_resources[tx_resources[modified]] = commit[:id] if tx_resources.include?(modified)
          end
        end
      end
      binding.pry
      # For each modified resource, get its content and updates the content
      # in Transifex.
      updated_resources.each do |tx_resource, commit_sha|
        settings.logger.info "process updated resource"
        tree_sha = github_api.get_commit(github_repo_name, commit_sha)[:commit][:tree][:sha]
        tree = github_api.tree(github_repo_name, tree_sha)

        tree[:tree].each do |file|
          settings.logger.info "process each tree entry:" + file[:path]
          if tx_resource.source_file == file[:path]
            settings.logger.info "process resource file:" + tx_resource.source_file
            blob = github_api.blob(github_repo_name, file[:sha])
            content = blob[:encoding] == 'utf-8' ? blob[:content] : Base64.decode64(blob[:content])

            transifex_project.api.update(tx_resource, content, github_branch)
            settings.logger.info '[' + github_branch + '] updated tx_resource:'  + tx_resource.inspect
          end
        end
      end

      # Upload translations if any
      updated_resource_translations.each do |tx_resource, translation|
        settings.logger.info "new branch/ merge :: process updated resource translation"

        translation.each do [lang, commit_sha]
          settings.logger.info "new branch/ merge :: process each translation lang:" + lang

          tree_sha = github_api.get_commit(github_repo_name, commit_sha)[:commit][:tree][:sha]
          tree = github_api.tree(github_repo_name, tree_sha)
          tree[:tree].each do |file|
            translation_path = tx_resource.translation_path(lang)
            # When the commit tree file path matches the translation path for the resource
            # after having replaced the placholder with the current lang
            # then this is a translation to be uploaded
            binding.pry
            if translation_path == file[:path]
              blob = github_api.blob(github_repo_name, file[:sha])
              content = blob[:encoding] == 'utf-8' ? blob[:content] : Base64.decode64(blob[:content])

              transifex_project.api.upload(tx_resource, lang, content, github_branch)
            end
          end
        end
      end

      200
    end
  end
end
