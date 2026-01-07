require "compiler/crystal/syntax"

module CRA
  module Analysis
    # Simple wrapper to represent raw text
    # class MacroId < Crystal::ASTNode
    #   getter value : String
    #   def initialize(@value)
    #   end
    #   def clone_without_location
    #     self
    #   end
    #   def accept_children(visitor)
    #   end
    #   def accept(visitor)
    #   end
    #   def to_s(io : IO)
    #     io << @value
    #   end
    # end

    class MacroInterpreter
      def initialize(@macro_def : Crystal::Macro, @call : Crystal::Call)
        @context = {} of String => Crystal::ASTNode
        setup_context
      end

      def interpret : String
        io = IO::Memory.new
        visit(@macro_def.body, io)
        io.to_s
      end

      private def setup_context
        macro_args = @macro_def.args
        call_args = @call.args
        splat_index = @macro_def.splat_index

        if splat_index
          # Handle splat
          # Pre-splat
          (0...splat_index).each do |i|
            arg = macro_args[i]
            val = i < call_args.size ? call_args[i] : (arg.default_value || Crystal::NilLiteral.new)
            @context[arg.name] = val
          end

          # Splat
          # How many args are post-splat?
          post_splat_count = macro_args.size - 1 - splat_index

          # The splat consumes everything remaining, minus what's needed for post-splat
          splat_size = [0, call_args.size - splat_index - post_splat_count].max
          splat_elements = call_args[splat_index, splat_size]

          splat_arg = macro_args[splat_index]
          @context[splat_arg.name] = Crystal::ArrayLiteral.new(splat_elements)

          # Post-splat
          (0...post_splat_count).each do |i|
             macro_idx = splat_index + 1 + i
             arg = macro_args[macro_idx]

             call_idx = splat_index + splat_size + i
             val = call_idx < call_args.size ? call_args[call_idx] : (arg.default_value || Crystal::NilLiteral.new)
             @context[arg.name] = val
          end

        else
          # No splat, simple mapping
          macro_args.each_with_index do |arg, i|
            call_arg = call_args[i]?

            # Handle default values if call_arg is missing
            if call_arg.nil? && arg.default_value
              call_arg = arg.default_value
            end

            if call_arg
              @context[arg.name] = call_arg
            else
              @context[arg.name] = Crystal::Nop.new
            end
          end
        end
      end

      private def visit(node : Crystal::ASTNode, io : IO)
        case node
        when Crystal::Expressions
          node.expressions.each { |e| visit(e, io) }
        when Crystal::MacroLiteral
          io << node.value
        when Crystal::MacroExpression
          value = evaluate(node.exp)
          # puts "DEBUG: MacroExpression #{node.exp} -> #{value} -> '#{value_to_s(value)}'"
          io << value_to_s(value)
        when Crystal::MacroIf
          cond = evaluate(node.cond)
          if truthy?(cond)
            visit(node.then, io)
          else
            visit(node.else, io)
          end
        when Crystal::MacroFor
          # Simplified for loop: {% for var in exp %}
          collection = evaluate(node.exp)

          elements = if collection.is_a?(Crystal::ArrayLiteral)
                       collection.elements
                     elsif collection.is_a?(Crystal::TupleLiteral)
                       collection.elements
                     else
                       nil
                     end

          if elements
            elements.each do |elem|
              # We only support single variable for now
              var_name = node.vars.first.name
              old_val = @context[var_name]?
              @context[var_name] = elem
              visit(node.body, io)
              if old_val
                @context[var_name] = old_val
              else
                @context.delete(var_name)
              end
            end
          end
        else
          # Ignore other nodes or print them?
        end
      end

      private def evaluate(node : Crystal::ASTNode) : Crystal::ASTNode
        case node
        when Crystal::Var
          @context[node.name]? || Crystal::Nop.new
        when Crystal::StringLiteral, Crystal::NumberLiteral, Crystal::ArrayLiteral, Crystal::BoolLiteral, Crystal::NilLiteral, Crystal::SymbolLiteral
          node
        when Crystal::Call
          obj = node.obj
          if obj
            receiver = evaluate(obj)
            execute_method(receiver, node.name, node.args)
          else
            # Top level macro method call? e.g. raise, puts (debug)
            Crystal::Nop.new
          end
        else
          node
        end
      end

      private def execute_method(receiver : Crystal::ASTNode, name : String, args : Array(Crystal::ASTNode)) : Crystal::ASTNode
        case name
        when "id"
          if receiver.is_a?(Crystal::StringLiteral) || receiver.is_a?(Crystal::SymbolLiteral)
             Crystal::StringLiteral.new(receiver.value)
          else
             receiver
          end
        when "is_a?"
           target_type = args.first
           if target_type.is_a?(Crystal::Path)
             type_name = target_type.names.last
             result = case type_name
                      when "TypeDeclaration"
                        receiver.is_a?(Crystal::TypeDeclaration)
                      when "StringLiteral"
                        receiver.is_a?(Crystal::StringLiteral)
                      when "SymbolLiteral"
                        receiver.is_a?(Crystal::SymbolLiteral)
                      when "Call"
                        receiver.is_a?(Crystal::Call)
                      when "Var"
                        receiver.is_a?(Crystal::Var)
                      else
                        false
                      end
             Crystal::BoolLiteral.new(result)
           else
             Crystal::BoolLiteral.new(false)
           end
        when "var"
          if receiver.is_a?(Crystal::TypeDeclaration)
            receiver.var
          else
            receiver
          end
        when "type"
          if receiver.is_a?(Crystal::TypeDeclaration)
            receiver.declared_type
          else
            receiver
          end
        when "value"
           if receiver.is_a?(Crystal::TypeDeclaration)
             receiver.value || Crystal::NilLiteral.new
           else
             receiver
           end
        when "stringify"
          Crystal::StringLiteral.new(value_to_s(receiver))
        when "+"
           # String concatenation
           if receiver.is_a?(Crystal::StringLiteral) && args.first?
             arg = evaluate(args.first)
             if arg.is_a?(Crystal::StringLiteral)
               Crystal::StringLiteral.new(receiver.value + arg.value)
             else
               receiver
             end
           else
             receiver
           end
        else
          receiver
        end
      end

      private def value_to_s(node : Crystal::ASTNode) : String
        case node
        when Crystal::StringLiteral
          node.value
        when Crystal::SymbolLiteral
          node.value
        when Crystal::Var
          node.name
        when Crystal::TypeDeclaration
          "#{value_to_s(node.var)} : #{value_to_s(node.declared_type)}"
        when Crystal::Path
          node.names.join("::")
        when Crystal::Generic
          "#{value_to_s(node.name)}(#{node.type_vars.map { |t| value_to_s(t) }.join(", ")})"
        when Crystal::Call
          # Handle simple calls like "foo" or "foo.bar"
          if obj = node.obj
            obj_value = value_to_s(obj)
            return node.name if obj_value.empty?
            "#{obj_value}.#{node.name}"
          else
            node.name
          end
        else
          # Fallback for unknown nodes
          ""
        end
      end

      private def truthy?(node : Crystal::ASTNode)
        !node.is_a?(Crystal::NilLiteral) && !node.is_a?(Crystal::Nop) && !(node.is_a?(Crystal::BoolLiteral) && node.value == false)
      end
    end
  end
end
