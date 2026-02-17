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
            if ref.union?
              types.concat(ref.union_types)
            else
              types << ref
            end
          end
        end
        return nil if types.empty?
        return types.first if types.size == 1
        TypeRef.union(types)
      when Crystal::Self
        TypeRef.named("self")
      when Crystal::NumberLiteral
        TypeRef.named(node.value)
      when Crystal::ProcNotation
        proc_type_ref_from_notation(node)
      else
        nil
      end
    end

    private def type_ref_from_value(node : Crystal::ASTNode) : TypeRef?
      case node
      when Crystal::BoolLiteral
        TypeRef.named("Bool")
      when Crystal::NilLiteral
        TypeRef.named("Nil")
      when Crystal::StringLiteral
        TypeRef.named("String")
      when Crystal::CharLiteral
        TypeRef.named("Char")
      when Crystal::SymbolLiteral
        TypeRef.named("Symbol")
      when Crystal::RegexLiteral
        TypeRef.named("Regex")
      when Crystal::NumberLiteral
        TypeRef.named(number_literal_type(node))
      when Crystal::Cast
        type_ref_from_type(node.to)
      when Crystal::NilableCast
        type_ref_from_type(node.to)
      when Crystal::Call
        if node.name == "new" || node.name == "null" || node.name == "malloc"
          if obj = node.obj
            type_ref_from_type(obj)
          end
        end
      when Crystal::ArrayLiteral
        if of_type = node.of
          if inner = type_ref_from_type(of_type)
            TypeRef.named("Array", [inner])
          end
        elsif first_elem = node.elements.first?
          if inner = type_ref_from_value(first_elem)
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
        elsif first_entry = node.entries.first?
          key = type_ref_from_value(first_entry.key)
          value = type_ref_from_value(first_entry.value)
          if key && value
            TypeRef.named("Hash", [key, value])
          end
        end
      when Crystal::ProcLiteral
        proc_type_ref_from_literal(node)
      else
        nil
      end
    end

    private def proc_type_ref_from_literal(node : Crystal::ProcLiteral) : TypeRef?
      proc_def = node.def
      args = [] of TypeRef
      proc_def.args.each do |arg|
        if restriction = arg.restriction
          if ref = type_ref_from_type(restriction)
            args << ref
          else
            return nil
          end
        else
          return nil
        end
      end
      ret = if ret_type = proc_def.return_type
              type_ref_from_type(ret_type)
            end
      args << (ret || TypeRef.named("Nil"))
      TypeRef.named("Proc", args)
    end

    private def proc_type_ref_from_notation(node : Crystal::ProcNotation) : TypeRef?
      args = [] of TypeRef
      if inputs = node.inputs
        inputs.each do |input|
          if ref = type_ref_from_type(input)
            args << ref
          else
            return nil
          end
        end
      end
      ret = if output = node.output
              type_ref_from_type(output)
            end
      args << (ret || TypeRef.named("Nil"))
      TypeRef.named("Proc", args)
    end

    private def number_literal_type(node : Crystal::NumberLiteral) : String
      case node.kind
      when .i8?   then "Int8"
      when .i16?  then "Int16"
      when .i32?  then "Int32"
      when .i64?  then "Int64"
      when .i128? then "Int128"
      when .u8?   then "UInt8"
      when .u16?  then "UInt16"
      when .u32?  then "UInt32"
      when .u64?  then "UInt64"
      when .u128? then "UInt128"
      when .f32?  then "Float32"
      when .f64?  then "Float64"
      else
        node.value.includes?('.') ? "Float64" : "Int32"
      end
    end
  end
end
