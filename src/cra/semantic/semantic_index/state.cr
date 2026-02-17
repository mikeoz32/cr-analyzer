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
    @class_includes : Hash(String, Array(Crystal::ASTNode)) = {} of String => Array(Crystal::ASTNode)
    @module_includes : Hash(String, Array(Crystal::ASTNode)) = {} of String => Array(Crystal::ASTNode)
    @class_superclass : Hash(String, Crystal::ASTNode) = {} of String => Crystal::ASTNode
    @elements_by_file : Hash(String, Array(PsiElement)) = {} of String => Array(PsiElement)
    @type_defs_by_name : Hash(String, Hash(String, TypeDefinition)) = {} of String => Hash(String, TypeDefinition)
    @types_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @aliases_by_name : Hash(String, Hash(String, CRA::Psi::Alias)) = {} of String => Hash(String, CRA::Psi::Alias)
    @aliases_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @includes_by_file : Hash(String, Array(IncludeEntry)) = {} of String => Array(IncludeEntry)
    @superclass_defs : Hash(String, Hash(String, Crystal::ASTNode)) = {} of String => Hash(String, Crystal::ASTNode)
    @superclass_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @reverse_dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @dependency_sources : Hash(String, Hash(String, Hash(String, Bool))) = {} of String => Hash(String, Hash(String, Bool))
    @deps_by_file : Hash(String, Array(DependencyEdge)) = {} of String => Array(DependencyEdge)
    @call_graph : Hash(String, Array(CallEdge)) = {} of String => Array(CallEdge)
    @reverse_call_graph : Hash(String, Array(CallEdge)) = {} of String => Array(CallEdge)
    @method_by_key : Hash(String, CRA::Psi::Method) = {} of String => CRA::Psi::Method
    @methods_by_file : Hash(String, Array(CRA::Psi::Method)) = {} of String => Array(CRA::Psi::Method)
    @pending_yield_defs : Array({Crystal::Def, PsiElement, Method}) = [] of {Crystal::Def, PsiElement, Method}

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
      getter node : Crystal::ASTNode
      getter kind : Symbol

      def initialize(@owner_name : String, @node : Crystal::ASTNode, @kind : Symbol)
      end
    end

    struct DependencyEdge
      getter owner : String
      getter dependency : String

      def initialize(@owner : String, @dependency : String)
      end
    end

    # Public wrappers for indexer use (e.g. YieldTypeExtractor).
    def resolve_type_ref_public(type_ref : TypeRef) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      resolve_type_ref(type_ref, nil)
    end

    def find_methods_in_type(owner : CRA::Psi::PsiElement, name : String, class_method : Bool) : Array(Method)
      find_methods_with_ancestors(owner, name, class_method)
    end

    def add_pending_yield_def(def_node : Crystal::Def, owner : PsiElement, method : Method)
      @pending_yield_defs << {def_node, owner, method}
    end

    def resolve_pending_yield_types
      @pending_yield_defs.each do |def_node, owner, method|
        next unless method.block_arg_types.empty?
        body = def_node.body
        next unless body
        extractor = SemanticIndexer::YieldTypeExtractor.new(def_node, owner, self)
        body.accept(extractor)
        unless extractor.types.empty?
          method.block_arg_types = extractor.types
        end
      end
      @pending_yield_defs.clear
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
