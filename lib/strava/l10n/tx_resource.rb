# The @ sign is used to separate the name of the resource from the target branch name
BRANCH_SEPARATOR = '_B_'

module Strava
  module L10n
    class TxResource
      def self.branch_separator
        BRANCH_SEPARATOR
      end

      def initialize(project_slug, resource_slug, type, source_lang, source_file,
          lang_map, translation_file)
        @project_slug = project_slug
        @resource_slug = resource_slug
        @type = type
        @source_lang = source_lang
        @source_file = source_file
        @lang_map = {}
        if lang_map
          result = {}
          lang_map.split(',').each do |m|
            key_value = m.split(':', 2)
            result[key_value[0].strip] = key_value[1].strip
          end
          @lang_map = result
        end
        @translation_file = translation_file
      end

      def project_slug
        @project_slug
      end

      def resource_slug(branch = nil)
        if branch.nil? or branch == 'master'
          @resource_slug
        else
          @resource_slug + BRANCH_SEPARATOR + branch
        end
      end

      def type
        @type
      end

      def source_lang
        @source_lang
      end

      def source_file
        @source_file
      end

      def lang_map(tx_lang)
        if @lang_map.include?(tx_lang)
          @lang_map[tx_lang]
        else
          tx_lang
	end
      end

      def translation_path(language)
        path = String.new(@translation_file)
        path.gsub! '<lang>', language
        path
      end

    end
  end
end
