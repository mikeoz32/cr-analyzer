require "compiler/crystal/syntax"
require "./ast"
require "./extensions"

module CRA::Psi
  # Helpers for extracting lightweight type references from syntax or simple values.
  module TypeRefHelper
    private def type_ref_from_type(node : Crystal::ASTNode) : TypeRef?
      case node
      when Crystal::Path
        TypeRef.named(node.full)
      when Crystal::Generic
        args = [] of TypeRef
        node.type_vars.each do |arg|
          if ref = type_ref_from_type(arg)
            args << ref
          end
        end
        name = case generic_name = node.name
               when Crystal::Path
                 generic_name.full
               else
                 generic_name.to_s
               end
        TypeRef.named(name, args)
      when Crystal::Metaclass
        type_ref_from_type(node.name)
      when Crystal::Union
        types = [] of TypeRef
        node.types.each do |type|
          if ref = type_ref_from_type(type)
            types << ref
          end
        end
        return nil if types.empty?
        return types.first if types.size == 1
        TypeRef.union(types)
      when Crystal::Self
        TypeRef.named("self")
      else
        nil
      end
    end

    private def type_ref_from_value(node : Crystal::ASTNode) : TypeRef?
      case node
      when Crystal::Cast
        type_ref_from_type(node.to)
      when Crystal::NilableCast
        type_ref_from_type(node.to)
      when Crystal::Call
        if node.name == "new"
          if obj = node.obj
            type_ref_from_type(obj)
          end
        end
      when Crystal::ArrayLiteral
        if of_type = node.of
          if inner = type_ref_from_type(of_type)
            TypeRef.named("Array", [inner])
          end
        end
      when Crystal::HashLiteral
        if of_entry = node.of
          key = type_ref_from_type(of_entry.key)
          value = type_ref_from_type(of_entry.value)
          if key && value
            TypeRef.named("Hash", [key, value])
          end
        end
      else
        nil
      end
    end
  end
end
