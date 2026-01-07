require "../completion"
require "uri"

module CRA
  class RequirePathCompletionProvider
    include CompletionProvider

    def complete(context : CompletionContext) : Array(Types::CompletionItem)
      prefix = context.require_prefix
      return [] of Types::CompletionItem unless prefix

      root_path = context.root.path
      document_path = URI.parse(context.document_uri).path
      base_dir = if prefix.starts_with?("./") || prefix.starts_with?("../")
                   File.dirname(document_path)
                 else
                   src_path = File.join(root_path, "src")
                   Dir.exists?(src_path) ? src_path : root_path
                 end

      dir_part, partial = split_prefix(prefix)
      search_dir = dir_part.empty? ? base_dir : File.expand_path(dir_part, base_dir)
      return [] of Types::CompletionItem unless Dir.exists?(search_dir)

      items = [] of Types::CompletionItem
      Dir.glob(File.join(search_dir, "*")) do |entry|
        name = File.basename(entry)
        next if name.starts_with?(".")
        relative = dir_part.empty? ? name : File.join(dir_part, name)

        if File.directory?(entry)
          items << Types::CompletionItem.new(
            label: relative,
            kind: Types::CompletionItemKind::Folder
          )
          next
        end

        next unless name.ends_with?(".cr")
        next unless partial.empty? || name.starts_with?(partial)
        relative = relative[0...-3]
        items << Types::CompletionItem.new(
          label: relative,
          kind: Types::CompletionItemKind::File
        )
      end

      items
    end

    private def split_prefix(prefix : String) : {String, String}
      return {"", prefix} unless prefix.includes?("/")
      parts = prefix.split("/")
      partial = parts.pop || ""
      dir_part = parts.join("/")
      {dir_part, partial}
    end
  end
end
