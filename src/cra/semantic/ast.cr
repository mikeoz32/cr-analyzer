require "../types.cr"
module CRA
  module Psi
    class Location
      getter start_line : Int32
      getter start_character : Int32
      getter end_line : Int32
      getter end_character : Int32

      def initialize(@start_line : Int32, @start_character : Int32, @end_line : Int32, @end_character : Int32)
      end

      def to_range : Types::Range
        Types::Range.new(
          start_position: Types::Position.new(line: @start_line, character: @start_character),
          end_position: Types::Position.new(line: @end_line, character: @end_character)
        )
      end
    end

    class PsiElement
      property file : String?
      property location : Location?
      getter name : String

      def initialize(@file : String?, @name : String, @location : Location? = nil)
      end
    end

    class Module < PsiElement
      getter classes : Array(Class)
      getter methods : Array(Method)
      getter owner : Module?
      def initialize(@file : String?, @name : String, @classes : Array(Class), @methods : Array(Method), @owner : Module? = nil, @location : Location? = nil)
      end
    end

    class Class < PsiElement
      getter parent : Class?
      getter methods : Array(Method)
      getter instance_vars : Array(InstanceVar)
      getter class_vars : Array(ClassVar)
      getter includes : Array(Module)
      getter owner : PsiElement | Nil

      def initialize(
        @file : String?,
        @name : String,
        @owner : PsiElement | Nil,
        @parent : Class? = nil,
        @methods : Array(Method) = [] of Method,
        @instance_vars : Array(InstanceVar) = [] of InstanceVar,
        @class_vars : Array(ClassVar) = [] of ClassVar,
        @includes : Array(Module) = [] of Module,
        @location : Location? = nil)
      end
    end

    class Method < PsiElement
      getter return_type : String
      getter parameters : Array(String)
      getter min_arity : Int32
      getter max_arity : Int32?
      getter class_method : Bool
      getter owner : PsiElement | Nil
      def initialize(
        @file : String?,
        @name : String,
        @return_type : String,
        @min_arity : Int32,
        @max_arity : Int32?,
        @class_method : Bool,
        @owner : PsiElement | Nil,
        @parameters : Array(String) = [] of String,
        @location : Location? = nil)
      end
    end

    class InstanceVar < PsiElement
      getter type : String
      getter owner : Class
      def initialize(@file : String?, @name : String, @type : String, @owner : Class, @location : Location? = nil)
      end
    end

    class ClassVar < PsiElement
      getter type : String
      getter owner : Class
      def initialize(@file : String?, @name : String, @type : String, @owner : Class, @location : Location? = nil)
      end
    end

    class Enum < PsiElement
      getter members : Array(EnumMember)
      getter methods : Array(Method)
      getter owner : PsiElement | Nil

      def initialize(
        @file : String?,
        @name : String,
        @members : Array(EnumMember) = [] of EnumMember,
        @methods : Array(Method) = [] of Method,
        @owner : PsiElement | Nil = nil,
        @location : Location? = nil)
      end
    end

    class EnumMember < PsiElement
      getter owner : Enum
      def initialize(@file : String?, @name : String, @owner : Enum, @location : Location? = nil)
      end
    end

    class LocalVar < PsiElement
      getter owner : PsiElement | Nil
      def initialize(@file : String?, @name : String, @owner : PsiElement | Nil = nil, @location : Location? = nil)
      end
    end

    class Annotation < PsiElement
      getter owner : Module | Class
      def initialize(@file : String?, @name : String, @owner : Module | Class, @location : Location? = nil)
      end
    end
  end
end
