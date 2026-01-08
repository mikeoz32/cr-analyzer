module CRA::Psi
  class SemanticIndex
    def register_macro_in_scope(node : Crystal::Macro, scope : String)
      @macro_defs[scope] ||= {} of String => Array(Crystal::Macro)
      @macro_defs[scope][node.name] ||= [] of Crystal::Macro
      @macro_defs[scope][node.name] << node
    end

    def expand_macro_call_in_scope(node : Crystal::Call, scope : String, indexer : SemanticIndexer)
      return unless node.obj.nil?
      return if @macro_expansion_depth >= MAX_MACRO_EXPANSION_DEPTH

      owner : PsiElement? = nil
      if indexer.owner_stack_empty? && !scope.empty?
        owner = find_type(scope)
      end

      if macro_def = find_macro(node.name, scope, node)
        expand_user_macro(macro_def, node, owner, indexer)
        return
      end

      if file = @current_file
        if expansion = CRA::Analysis::MacroExpander.expand_builtin(node, file)
          expand_virtual(expansion, owner, indexer)
        end
      end
    end

    private def expand_user_macro(macro_def : Crystal::Macro, call : Crystal::Call, owner : PsiElement?, indexer : SemanticIndexer)
      content = CRA::Analysis::MacroInterpreter.new(macro_def, call).interpret
      return if content.empty?

      macro_uri = macro_uri_for(call)
      expand_virtual({macro_uri, content}, owner, indexer)
    rescue ex
      Log.info { "Macro expansion failed for #{call.name}: #{ex.message}" }
    end

    private def expand_virtual(expansion : {String, String}, owner : PsiElement?, indexer : SemanticIndexer)
      uri, content = expansion
      parser = Crystal::Parser.new(content)
      expanded_node = parser.parse

      @macro_expansion_depth += 1
      begin
        indexer.index_virtual(expanded_node, uri, owner)
      ensure
        @macro_expansion_depth -= 1
      end
    rescue ex : Crystal::SyntaxException
      Log.info { "Error parsing expanded macro: #{ex.message}" }
    end

    private def macro_uri_for(call : Crystal::Call) : String
      file = @current_file || "file://"
      line = call.location.try(&.line_number) || 0
      col = call.location.try(&.column_number) || 0
      "crystal-macro:#{file.sub("file://", "")}/#{call.name}/#{line}_#{col}.cr"
    end

    private def find_macro(name : String, context : String, call : Crystal::Call) : Crystal::Macro?
      scopes = [] of String
      if !context.empty?
        parts = context.split("::")
        while parts.size > 0
          scopes << parts.join("::")
          parts.pop
        end
      end
      scopes << ""

      scopes.each do |scope|
        if scope_defs = @macro_defs[scope]?
          if defs = scope_defs[name]?
            if selected = select_macro_def(defs, call)
              return selected
            end
          end
        end
      end
      nil
    end

    private def select_macro_def(defs : Array(Crystal::Macro), call : Crystal::Call) : Crystal::Macro?
      defs.each do |macro_def|
        return macro_def if macro_matches_call?(macro_def, call)
      end
      defs.first?
    end

    private def macro_matches_call?(macro_def : Crystal::Macro, call : Crystal::Call) : Bool
      arity = macro_arity(macro_def)
      call_arity = call.args.size
      return false if call_arity < arity[:min]
      max = arity[:max]
      return true if max.nil?
      call_arity <= max
    end

    private def macro_arity(macro_def : Crystal::Macro) : {min: Int32, max: Int32?}
      splat_index = macro_def.splat_index
      required = 0
      macro_def.args.each_with_index do |arg, idx|
        next if splat_index && idx == splat_index
        required += 1 unless arg.default_value
      end
      max = splat_index ? nil : macro_def.args.size
      {min: required, max: max}
    end
  end
end
