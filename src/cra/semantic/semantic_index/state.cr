module CRA::Psi
  class SemanticIndex
    include TypeRefHelper
    include CRA::CompletionProvider

    Log = ::Log.for(self)

    @roots : Array(PsiElement) = [] of PsiElement

    @current_file : String? = nil
    @macro_defs : Hash(String, Hash(String, Array(Crystal::Macro))) = {} of String => Hash(String, Array(Crystal::Macro))
    @macro_expansion_depth : Int32 = 0
    MAX_MACRO_EXPANSION_DEPTH = 4
    # Tracks include/superclass relationships for ancestor method lookups.
    @class_includes : Hash(String, Array(String)) = {} of String => Array(String)
    @module_includes : Hash(String, Array(String)) = {} of String => Array(String)
    @class_superclass : Hash(String, String) = {} of String => String
    @elements_by_file : Hash(String, Array(PsiElement)) = {} of String => Array(PsiElement)
    @type_defs_by_name : Hash(String, Hash(String, TypeDefinition)) = {} of String => Hash(String, TypeDefinition)
    @types_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @aliases_by_name : Hash(String, Hash(String, CRA::Psi::Alias)) = {} of String => Hash(String, CRA::Psi::Alias)
    @aliases_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @includes_by_file : Hash(String, Array(IncludeEntry)) = {} of String => Array(IncludeEntry)
    @superclass_defs : Hash(String, Hash(String, String)) = {} of String => Hash(String, String)
    @superclass_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @reverse_dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @dependency_sources : Hash(String, Hash(String, Hash(String, Bool))) = {} of String => Hash(String, Hash(String, Bool))
    @deps_by_file : Hash(String, Array(DependencyEdge)) = {} of String => Array(DependencyEdge)
    @call_graph : Hash(String, Array(CallEdge)) = {} of String => Array(CallEdge)
    @reverse_call_graph : Hash(String, Array(CallEdge)) = {} of String => Array(CallEdge)
    @method_by_key : Hash(String, CRA::Psi::Method) = {} of String => CRA::Psi::Method
    @methods_by_file : Hash(String, Array(CRA::Psi::Method)) = {} of String => Array(CRA::Psi::Method)

    struct CallEdge
      getter target_key : String
      getter location : CRA::Psi::Location?

      def initialize(@target_key : String, @location : CRA::Psi::Location?)
      end
    end

    struct TypeDefinition
      getter kind : Symbol
      getter location : Location?
      getter type_vars : Array(String)

      def initialize(@kind : Symbol, @location : Location?, @type_vars : Array(String))
      end
    end

    struct IncludeEntry
      getter owner_name : String
      getter name : String
      getter kind : Symbol

      def initialize(@owner_name : String, @name : String, @kind : Symbol)
      end
    end

    struct DependencyEdge
      getter owner : String
      getter dependency : String

      def initialize(@owner : String, @dependency : String)
      end
    end

    # Lightweight type hints collected from the current lexical scope.
    class TypeEnv
      getter locals : Hash(String, TypeRef)
      getter ivars : Hash(String, TypeRef)
      getter cvars : Hash(String, TypeRef)

      def initialize
        @locals = {} of String => TypeRef
        @ivars = {} of String => TypeRef
        @cvars = {} of String => TypeRef
      end
    end
  end
end
