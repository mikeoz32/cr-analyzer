require "json"
require "./nested_json"

module CRA
  module Types
    alias DocumentUri = String

    abstract class Message
      include JSON::Serializable

      property jsonrpc : String = "2.0"
    end

    # Base request message. Concrete requests are selected via the JSON discriminator
    # on the `method` field.
    abstract class Request < Message
      property method : String
      property id : String | Int32

      use_json_discriminator "method", {
        "initialize"                => InitializeRequest,
        "textDocument/completion"   => CompletionRequest,
      }
    end

    class Notification < Message
      property method : String
    end

    # LSP response wrapper. The result type is a union of the result payloads we
    # currently emit; it can be extended as new handlers are added.
    alias ResponseResult = InitializeResult | CompletionList | Array(CompletionItem) | JSON::Any

    class Response < Message
      property id : String | Int32 | Nil
      @[JSON::Field(key: "result")]
      property result : ResponseResult?
      @[JSON::Field(key: "error")]
      property error : ResponseError?

      def initialize(@id : String | Int32 | Nil, @result : ResponseResult? = nil, @error : ResponseError? = nil)
      end
    end

    class ResponseError
      include JSON::Serializable

      property code : Int32
      property message : String
      property data : JSON::Any?

      def initialize(@code : Int32, @message : String, @data : JSON::Any? = nil)
      end
    end

    module ErrorCodes
      ERROR_CODE_INVALID_REQUEST  = -32600
      ERROR_CODE_METHOD_NOT_FOUND = -32601
      ERROR_CODE_INVALID_PARAMS   = -32602
      ERROR_CODE_INTERNAL_ERROR   = -32603
      ERROR_CODE_SERVER_ERROR     = -32000..-32099
      ERROR_CODE_SERVER_ERROR_MIN = -32000
      ERROR_CODE_SERVER_ERROR_MAX = -32099
      ERROR_CODE_PARSE_ERROR      = -32700
    end

    class Position
      include JSON::Serializable

      property line : Int32
      property character : Int32
    end

    class Range
      include JSON::Serializable

      @[JSON::Field(key: "start")]
      property start_position : Position

      @[JSON::Field(key: "end")]
      property end_position : Position
    end

    class Location
      include JSON::Serializable

      property uri : DocumentUri
      property range : Range
    end

    class WorkspaceFolder
      include JSON::Serializable

      property uri : String
      property name : String
    end

    class TextDocumentIdentifier
      include JSON::Serializable

      property uri : DocumentUri
    end

    class TextDocumentPositionParams
      include JSON::Serializable

      @[JSON::Field(key: "textDocument")]
      property text_document : TextDocumentIdentifier
      property position : Position
    end

    class WorkspaceClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "applyEdit")]
      property apply_edit : Bool?
      @[JSON::Field(key: "workspaceEdit")]
      property workspace_edit : Bool?
      @[JSON::Field(key: "didChangeWatchedFiles")]
      property did_change_watched_files : Bool?
      @[JSON::Field(key: "didChangeConfiguration")]
      property did_change_configuration : Bool?
      @[JSON::Field(key: "didChangeWorkspaceFolders")]
      property did_change_workspace_folders : Bool?
    end

    class TextDocumentClientCapabilities
      include JSON::Serializable

      property synchronization : Bool?
      property completion : Bool?
      property hover : Bool?
      @[JSON::Field(key: "signatureHelp")]
      property signature_help : Bool?
      property references : Bool?
      @[JSON::Field(key: "documentHighlight")]
      property document_highlight : Bool?
      @[JSON::Field(key: "documentSymbol")]
      property document_symbol : Bool?
      @[JSON::Field(key: "codeAction")]
      property code_action : Bool?
      @[JSON::Field(key: "codeLens")]
      property code_lens : Bool?
      @[JSON::Field(key: "documentFormatting")]
      property document_formatting : Bool?
      @[JSON::Field(key: "documentRangeFormatting")]
      property document_range_formatting : Bool?
      @[JSON::Field(key: "documentOnTypeFormatting")]
      property document_on_type_formatting : Bool?
      property rename : Bool?
      @[JSON::Field(key: "documentLink")]
      property document_link : Bool?
      @[JSON::Field(key: "colorProvider")]
      property color_provider : Bool?
      @[JSON::Field(key: "foldingRange")]
      property folding_range : Bool?
      @[JSON::Field(key: "selectionRange")]
      property selection_range : Bool?
      @[JSON::Field(key: "callHierarchy")]
      property call_hierarchy : Bool?
      @[JSON::Field(key: "semanticTokens")]
      property semantic_tokens : Bool?
      @[JSON::Field(key: "linkedEditingRange")]
      property linked_editing_range : Bool?
      property moniker : Bool?
    end

    class ClientCapabilities
      include JSON::Serializable

      property workspace : WorkspaceClientCapabilities?
      @[JSON::Field(key: "textDocument")]
      property text_document : TextDocumentClientCapabilities?
    end

    class ServerCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "completionProvider")]
      property completion_provider : CompletionOptions?
    end

    class InitializeResult
      include JSON::Serializable

      property capabilities : ServerCapabilities
    end

    class CompletionOptions
      include JSON::Serializable

      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = false

      @[JSON::Field(key: "triggerCharacters")]
      property trigger_characters : Array(String)?
    end

    enum CompletionTriggerKind : Int32
      Invoked = 1
      TriggerCharacter = 2
      TriggerForIncompleteCompletions = 3
    end

    enum CompletionItemKind : Int32
      Text = 1
      Method = 2
      Function = 3
      Constructor = 4
      Field = 5
      Variable = 6
      Class = 7
      Interface = 8
      Module = 9
      Property = 10
      Unit = 11
      Value = 12
      Enum = 13
      Keyword = 14
      Snippet = 15
      Color = 16
      File = 17
      Reference = 18
      Folder = 19
      EnumMember = 20
      Constant = 21
      Struct = 22
      Event = 23
      Operator = 24
      TypeParameter = 25
    end

    enum InsertTextFormat : Int32
      PlainText = 1
      Snippet = 2
    end

    class CompletionContext
      include JSON::Serializable

      @[JSON::Field(key: "triggerKind")]
      property trigger_kind : CompletionTriggerKind

      @[JSON::Field(key: "triggerCharacter")]
      property trigger_character : String?
    end

    class CompletionItem
      include JSON::Serializable

      property label : String
      property kind : CompletionItemKind?
      property detail : String?
      property documentation : String?

      @[JSON::Field(key: "insertText")]
      property insert_text : String?

      @[JSON::Field(key: "insertTextFormat")]
      property insert_text_format : InsertTextFormat?
    end

    class CompletionList
      include JSON::Serializable

      @[JSON::Field(key: "isIncomplete")]
      property is_incomplete : Bool = false

      property items : Array(CompletionItem)
    end

    class InitializeRequest < Request
      @[JSON::Field(nested: "params", key: "capabilities")]
      property capabilities : ClientCapabilities?

      @[JSON::Field(nested: "params", key: "processId")]
      property process_id : Int32?

      @[JSON::Field(nested: "params", key: "rootPath")]
      property root_path : String?

      @[JSON::Field(nested: "params", key: "rootUri")]
      property root_uri : String?

      @[JSON::Field(nested: "params", key: "workspaceFolders")]
      property workspace_folders : Array(WorkspaceFolder)?
    end

    class CompletionRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position

      @[JSON::Field(nested: "params", key: "context")]
      property context : CompletionContext?
    end
  end
end
