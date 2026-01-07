require "json"
require "./nested_json"

module CRA
  module Types
    alias IntegerOrString = Int32 | String
    alias ProgressToken = IntegerOrString
    alias DocumentUri = String
    alias Locations = Array(Location)
    alias LocationLinks = Array(LocationLink)
    alias DocumentSymbols = Array(DocumentSymbol)
    alias SymbolInformations = Array(SymbolInformation)
    alias TextEdits = Array(TextEdit | AnnotatedTextEdit | SnippetTextEdit)

    # ---- Completion trigger kinds ----

    enum CompletionTriggerKind : Int32
      Invoked = 1
      TriggerCharacter = 2
      TriggerForIncompleteCompletions = 3
    end

    # LSP sends trigger kinds as integers; use a converter so JSON::Serializable
    # accepts the numeric representation instead of expecting enum names.
    module CompletionTriggerKindConverter
      def self.from_json(pull : JSON::PullParser)
        CompletionTriggerKind.from_value(pull.read_int.to_i32)
      end

      def self.to_json(value : CompletionTriggerKind, json : JSON::Builder)
        json.number(value.to_i)
      end
    end

    # Completion item kinds are numeric in LSP; accept both ints and strings.
    module CompletionItemKindConverter
      def self.from_json(pull : JSON::PullParser)
        case pull.kind
        when JSON::PullParser::Kind::Int
          CompletionItemKind.from_value(pull.read_int.to_i32)
        when JSON::PullParser::Kind::String
          CompletionItemKind.parse(pull.read_string)
        else
          pull.read_null
          nil
        end
      end

      def self.to_json(value : CompletionItemKind, json : JSON::Builder)
        json.number(value.to_i)
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

    # ---- Window messaging ----

    enum MessageType : Int32
      Error   = 1
      Warning = 2
      Info    = 3
      Log     = 4
    end

    class ShowMessageParams
      include JSON::Serializable

      property type : MessageType
      property message : String

      def initialize(@type : MessageType, @message : String)
      end
    end

    class MessageActionItem
      include JSON::Serializable

      property title : String

      def initialize(@title : String)
      end
    end

    class ShowMessageRequestParams < ShowMessageParams
      include JSON::Serializable

      property actions : Array(MessageActionItem)?

      def initialize(type : MessageType, message : String, @actions : Array(MessageActionItem)? = nil)
        super(type, message)
      end
    end

    class LogMessageParams
      include JSON::Serializable

      property type : MessageType
      property message : String

      def initialize(@type : MessageType, @message : String)

      end
    end


    # Base protocol message
    abstract class Message
      include JSON::Serializable

      property jsonrpc : String = "2.0"

      use_json_discriminator "method", {
        "initialize"                => InitializeRequest,
        "initialized"               => InitializedNotification,
        "shutdown"                  => ShutdownRequest,
        "textDocument/completion"   => CompletionRequest,
        "textDocument/hover"        => HoverRequest,
        "textDocument/signatureHelp" => SignatureHelpRequest,
        "textDocument/definition"   => DefinitionRequest,
        "textDocument/references"   => ReferencesRequest,
        "textDocument/documentSymbol" => DocumentSymbolRequest,
        "workspace/symbol"          => WorkspaceSymbolRequest,
        "textDocument/formatting"   => DocumentFormattingRequest,
        "textDocument/rangeFormatting" => DocumentRangeFormattingRequest,
        "textDocument/rename"       => RenameRequest,
        "textDocument/diagnostic"   => DocumentDiagnosticRequest,
        "workspace/diagnostic"      => WorkspaceDiagnosticRequest,
        "window/showMessageRequest" => ShowMessageRequest,
        "exit"                      => ExitNotification,
        "textDocument/didOpen"      => DidOpenTextDocumentNotification,
        "textDocument/didChange"    => DidChangeTextDocumentNotification,
        "textDocument/didClose"     => DidCloseTextDocumentNotification,
        "textDocument/didSave"      => DidSaveTextDocumentNotification,
        "workspace/didChangeConfiguration" => DidChangeConfigurationNotification,
        "workspace/didChangeWatchedFiles"  => DidChangeWatchedFilesNotification,
        "window/showMessage"        => ShowMessageNotification,
        "window/logMessage"         => LogMessageNotification,
        "$/cancelRequest"           => CancelRequestNotification,
        "$/setTrace"                => SetTraceNotification,
      }
    end

    # Base request. Concrete subclasses are selected by the method discriminator.
    abstract class Request < Message
      property method : String
      property id : IntegerOrString

    end

    # Base notification. These are messages without an id.
    abstract class Notification < Message
      property method : String

      use_json_discriminator "method", {
        "initialized"                 => InitializedNotification,
        "exit"                        => ExitNotification,
        "textDocument/didOpen"        => DidOpenTextDocumentNotification,
        "textDocument/didChange"      => DidChangeTextDocumentNotification,
        "textDocument/didClose"       => DidCloseTextDocumentNotification,
        "textDocument/didSave"        => DidSaveTextDocumentNotification,
        "workspace/didChangeConfiguration" => DidChangeConfigurationNotification,
        "workspace/didChangeWatchedFiles"  => DidChangeWatchedFilesNotification,
        "window/showMessage"          => ShowMessageNotification,
        "window/logMessage"           => LogMessageNotification,
        "$/cancelRequest"             => CancelRequestNotification,
        "$/setTrace"                  => SetTraceNotification,
      }
    end

    # ---- Protocol control notifications ----

    class CancelParams
      include JSON::Serializable

      property id : IntegerOrString

      def initialize(@id : IntegerOrString)
      end
    end

    class CancelRequestNotification < Notification
      @[JSON::Field(nested: "params", key: "id")]
      property id : IntegerOrString
    end

    enum TraceValue
      Off
      Messages
      Verbose
    end

    class SetTraceNotification < Notification
      @[JSON::Field(nested: "params", key: "value")]
      property value : TraceValue
    end

    # Generic response wrapper. Result is a union of the known result payloads; unknown
    # results are captured via JSON::Any.
    alias DefinitionResult = Location | Locations | LocationLinks
    alias ReferencesResult = Array(Location)
    alias ResponseResult = InitializeResult | CompletionList | Hover | SignatureHelp | DefinitionResult | ReferencesResult | DocumentSymbols | SymbolInformations | WorkspaceEdit | TextEdits | DocumentDiagnosticReport | WorkspaceDiagnosticReport | MessageActionItem | JSON::Any

    class Response < Message
      include JSON::Serializable

      property id : IntegerOrString | Nil
      @[JSON::Field(key: "result")]
      property result : ResponseResult?
      @[JSON::Field(key: "error")]
      property error : ResponseError?

      def initialize(@id : IntegerOrString | Nil, @result : ResponseResult? = nil, @error : ResponseError? = nil)
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

    # ---- Core structures ----

    class Position
      include JSON::Serializable

      property line : Int32
      property character : Int32

      def initialize(@line : Int32, @character : Int32)
      end
    end

    class Range
      include JSON::Serializable

      @[JSON::Field(key: "start")]
      property start_position : Position

      @[JSON::Field(key: "end")]
      property end_position : Position

      def initialize(@start_position : Position, @end_position : Position)
      end
    end

    class Location
      include JSON::Serializable

      property uri : DocumentUri
      property range : Range

      def initialize(@uri : DocumentUri, @range : Range)
      end
    end

    class LocationLink
      include JSON::Serializable

      @[JSON::Field(key: "targetUri")]
      property target_uri : DocumentUri

      @[JSON::Field(key: "targetRange")]
      property target_range : Range

      @[JSON::Field(key: "targetSelectionRange")]
      property target_selection_range : Range

      @[JSON::Field(key: "originSelectionRange")]
      property origin_selection_range : Range?

      def initialize(@target_uri : DocumentUri, @target_range : Range, @target_selection_range : Range, @origin_selection_range : Range? = nil)
      end
    end

    enum DiagnosticSeverity : Int32
      Error = 1
      Warning = 2
      Information = 3
      Hint = 4
    end

    enum DiagnosticTag : Int32
      Unnecessary = 1
      Deprecated = 2
    end

    class CodeDescription
      include JSON::Serializable

      property href : String

      def initialize(@href : String)
      end
    end

    class DiagnosticRelatedInformation
      include JSON::Serializable

      property location : Location
      property message : String

      def initialize(@location : Location, @message : String)
      end
    end

    class Diagnostic
      include JSON::Serializable

      property range : Range
      property severity : DiagnosticSeverity?
      property code : Int32 | String | Nil
      @[JSON::Field(key: "codeDescription")]
      property code_description : CodeDescription?
      property source : String?
      property message : String
      @[JSON::Field(key: "tags")]
      property tags : Array(DiagnosticTag)?
      @[JSON::Field(key: "relatedInformation")]
      property related_information : Array(DiagnosticRelatedInformation)?
      property data : JSON::Any?

      def initialize(
        @range : Range,
        @message : String,
        @severity : DiagnosticSeverity? = nil,
        @code : Int32 | String | Nil = nil,
        @code_description : CodeDescription? = nil,
        @source : String? = nil,
        @tags : Array(DiagnosticTag)? = nil,
        @related_information : Array(DiagnosticRelatedInformation)? = nil,
        @data : JSON::Any? = nil
      )
      end
    end

    class Command
      include JSON::Serializable

      property title : String
      property tooltip : String?
      property command : String
      property arguments : Array(JSON::Any)?

      def initialize(@title : String, @command : String, @tooltip : String? = nil, @arguments : Array(JSON::Any)? = nil)
      end
    end

    class TextEdit
      include JSON::Serializable

      property range : Range
      @[JSON::Field(key: "newText")]
      property new_text : String

      def initialize(@range : Range, @new_text : String)
      end
    end

    class ChangeAnnotation
      include JSON::Serializable

      property label : String
      @[JSON::Field(key: "needsConfirmation")]
      property needs_confirmation : Bool?
      property description : String?

      def initialize(@label : String, @needs_confirmation : Bool? = nil, @description : String? = nil)
      end
    end

    alias ChangeAnnotationIdentifier = String

    class AnnotatedTextEdit < TextEdit
      include JSON::Serializable

      @[JSON::Field(key: "annotationId")]
      property annotation_id : ChangeAnnotationIdentifier

      def initialize(range : Range, new_text : String, @annotation_id : ChangeAnnotationIdentifier)
        super(range, new_text)
      end
    end

    class SnippetTextEdit
      include JSON::Serializable

      property range : Range
      property snippet : String
      @[JSON::Field(key: "annotationId")]
      property annotation_id : ChangeAnnotationIdentifier?

      def initialize(@range : Range, @snippet : String, @annotation_id : ChangeAnnotationIdentifier? = nil)
      end
    end

    abstract class ResourceOperation
      include JSON::Serializable

      property kind : String
      @[JSON::Field(key: "annotationId")]
      property annotation_id : ChangeAnnotationIdentifier?

      def initialize(@kind : String, @annotation_id : ChangeAnnotationIdentifier? = nil)
      end
    end

    class CreateFileOptions
      include JSON::Serializable

      property overwrite : Bool?
      @[JSON::Field(key: "ignoreIfExists")]
      property ignore_if_exists : Bool?

      def initialize(@overwrite : Bool? = nil, @ignore_if_exists : Bool? = nil)
      end
    end

    class CreateFile < ResourceOperation
      include JSON::Serializable

      property uri : DocumentUri
      property options : CreateFileOptions?

      def initialize(@uri : DocumentUri, @options : CreateFileOptions? = nil, annotation_id : ChangeAnnotationIdentifier? = nil)
        super("create", annotation_id)
      end
    end

    class RenameFileOptions
      include JSON::Serializable

      property overwrite : Bool?
      @[JSON::Field(key: "ignoreIfExists")]
      property ignore_if_exists : Bool?

      def initialize(@overwrite : Bool? = nil, @ignore_if_exists : Bool? = nil)
      end
    end

    class RenameFile < ResourceOperation
      include JSON::Serializable

      @[JSON::Field(key: "oldUri")]
      property old_uri : DocumentUri
      @[JSON::Field(key: "newUri")]
      property new_uri : DocumentUri
      property options : RenameFileOptions?

      def initialize(@old_uri : DocumentUri, @new_uri : DocumentUri, @options : RenameFileOptions? = nil, annotation_id : ChangeAnnotationIdentifier? = nil)
        super("rename", annotation_id)
      end
    end

    class DeleteFileOptions
      include JSON::Serializable

      property recursive : Bool?
      @[JSON::Field(key: "ignoreIfNotExists")]
      property ignore_if_not_exists : Bool?

      def initialize(@recursive : Bool? = nil, @ignore_if_not_exists : Bool? = nil)
      end
    end

    class DeleteFile < ResourceOperation
      include JSON::Serializable

      property uri : DocumentUri
      property options : DeleteFileOptions?

      def initialize(@uri : DocumentUri, @options : DeleteFileOptions? = nil, annotation_id : ChangeAnnotationIdentifier? = nil)
        super("delete", annotation_id)
      end
    end

    class TextDocumentEdit
      include JSON::Serializable

      @[JSON::Field(key: "textDocument")]
      property text_document : OptionalVersionedTextDocumentIdentifier
      property edits : TextEdits

      def initialize(@text_document : OptionalVersionedTextDocumentIdentifier, @edits : TextEdits)
      end
    end

    class WorkspaceEdit
      include JSON::Serializable

      property changes : Hash(DocumentUri, TextEdits)?
      @[JSON::Field(key: "documentChanges")]
      property document_changes : Array(TextDocumentEdit | CreateFile | RenameFile | DeleteFile)?
      @[JSON::Field(key: "changeAnnotations")]
      property change_annotations : Hash(ChangeAnnotationIdentifier, ChangeAnnotation)?

      def initialize(@changes : Hash(DocumentUri, TextEdits)? = nil, @document_changes : Array(TextDocumentEdit | CreateFile | RenameFile | DeleteFile)? = nil, @change_annotations : Hash(ChangeAnnotationIdentifier, ChangeAnnotation)? = nil)
      end
    end

    class TextDocumentIdentifier
      include JSON::Serializable

      property uri : DocumentUri

      def initialize(@uri : DocumentUri)
      end
    end

    class VersionedTextDocumentIdentifier < TextDocumentIdentifier
      include JSON::Serializable

      property version : Int32

      def initialize(uri : DocumentUri, @version : Int32)
        super(uri)
      end
    end

    class OptionalVersionedTextDocumentIdentifier < TextDocumentIdentifier
      include JSON::Serializable

      property version : Int32?

      def initialize(uri : DocumentUri, @version : Int32? = nil)
        super(uri)
      end
    end

    class TextDocumentItem
      include JSON::Serializable

      property uri : DocumentUri
      @[JSON::Field(key: "languageId")]
      property language_id : String
      property version : Int32
      property text : String

      def initialize(@uri : DocumentUri, @language_id : String, @version : Int32, @text : String)
      end
    end

    class TextDocumentPositionParams
      include JSON::Serializable

      @[JSON::Field(key: "textDocument")]
      property text_document : TextDocumentIdentifier
      property position : Position

      def initialize(@text_document : TextDocumentIdentifier, @position : Position)
      end
    end

    class TextDocumentContentChangeEvent
      include JSON::Serializable

      property range : Range?
      @[JSON::Field(key: "rangeLength")]
      property range_length : Int32?
      property text : String

      def initialize(@text : String, @range : Range? = nil, @range_length : Int32? = nil)
      end
    end

    # ---- File operations ----

    enum FileOperationPatternKind
      File
      Folder
    end

    class FileOperationPatternOptions
      include JSON::Serializable

      @[JSON::Field(key: "ignoreCase")]
      property ignore_case : Bool?

      def initialize(@ignore_case : Bool? = nil)
      end
    end

    class FileOperationPattern
      include JSON::Serializable

      property glob : String
      property matches : FileOperationPatternKind?
      property options : FileOperationPatternOptions?

      def initialize(@glob : String, @matches : FileOperationPatternKind? = nil, @options : FileOperationPatternOptions? = nil)
      end
    end

    class FileOperationFilter
      include JSON::Serializable

      property scheme : String?
      property pattern : FileOperationPattern

      def initialize(@pattern : FileOperationPattern, @scheme : String? = nil)
      end
    end

    class FileOperationRegistrationOptions
      include JSON::Serializable

      property filters : Array(FileOperationFilter)

      def initialize(@filters : Array(FileOperationFilter))
      end
    end

    class FileOperationOptions
      include JSON::Serializable

      @[JSON::Field(key: "didCreate")]
      property did_create : FileOperationRegistrationOptions?
      @[JSON::Field(key: "willCreate")]
      property will_create : FileOperationRegistrationOptions?
      @[JSON::Field(key: "didRename")]
      property did_rename : FileOperationRegistrationOptions?
      @[JSON::Field(key: "willRename")]
      property will_rename : FileOperationRegistrationOptions?
      @[JSON::Field(key: "didDelete")]
      property did_delete : FileOperationRegistrationOptions?
      @[JSON::Field(key: "willDelete")]
      property will_delete : FileOperationRegistrationOptions?

      def initialize(@did_create : FileOperationRegistrationOptions? = nil, @will_create : FileOperationRegistrationOptions? = nil, @did_rename : FileOperationRegistrationOptions? = nil, @will_rename : FileOperationRegistrationOptions? = nil, @did_delete : FileOperationRegistrationOptions? = nil, @will_delete : FileOperationRegistrationOptions? = nil)
      end
    end

    class WorkspaceFileOperationsClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "didCreate")]
      property did_create : Bool?
      @[JSON::Field(key: "willCreate")]
      property will_create : Bool?
      @[JSON::Field(key: "didRename")]
      property did_rename : Bool?
      @[JSON::Field(key: "willRename")]
      property will_rename : Bool?
      @[JSON::Field(key: "didDelete")]
      property did_delete : Bool?
      @[JSON::Field(key: "willDelete")]
      property will_delete : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @did_create : Bool? = nil, @will_create : Bool? = nil, @did_rename : Bool? = nil, @will_rename : Bool? = nil, @did_delete : Bool? = nil, @will_delete : Bool? = nil)
      end
    end

    enum TextDocumentSyncKind : Int32
      None = 0
      Full = 1
      Incremental = 2
    end

    module TextDocumentSyncKindConverter
      def self.from_json(pull : JSON::PullParser)
        TextDocumentSyncKind.from_value(pull.read_int.to_i32)
      end

      def self.to_json(value : TextDocumentSyncKind, json : JSON::Builder)
        json.number(value.to_i)
      end
    end

    class SaveOptions
      include JSON::Serializable

      @[JSON::Field(key: "includeText")]
      property include_text : Bool?

      def initialize(@include_text : Bool? = nil)
      end
    end

    class TextDocumentSyncOptions
      include JSON::Serializable

      @[JSON::Field(key: "openClose")]
      property open_close : Bool?
      @[JSON::Field(converter: ::CRA::Types::TextDocumentSyncKindConverter)]
      property change : TextDocumentSyncKind?
      @[JSON::Field(key: "willSave")]
      property will_save : Bool?
      @[JSON::Field(key: "willSaveWaitUntil")]
      property will_save_wait_until : Bool?
      property save : SaveOptions | Bool | Nil

      def initialize(
        @open_close : Bool? = nil,
        @change : TextDocumentSyncKind? = nil,
        @will_save : Bool? = nil,
        @will_save_wait_until : Bool? = nil,
        @save : SaveOptions | Bool | Nil = nil
      )
      end
    end

    class WorkspaceFolder
      include JSON::Serializable

      property uri : DocumentUri
      property name : String

      def initialize(@uri : DocumentUri, @name : String)
      end
    end

    # ---- Client capabilities ----

    class ChangeAnnotationSupport
      include JSON::Serializable

      @[JSON::Field(key: "groupsOnLabel")]
      property groups_on_label : Bool?

      def initialize(@groups_on_label : Bool? = nil)
      end
    end

    class WorkspaceEditClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "documentChanges")]
      property document_changes : Bool?

      @[JSON::Field(key: "resourceOperations")]
      property resource_operations : Array(String)?

      @[JSON::Field(key: "failureHandling")]
      property failure_handling : String?

      @[JSON::Field(key: "normalizesLineEndings")]
      property normalizes_line_endings : Bool?

      @[JSON::Field(key: "changeAnnotationSupport")]
      property change_annotation_support : ChangeAnnotationSupport?

      def initialize(
        @document_changes : Bool? = nil,
        @resource_operations : Array(String)? = nil,
        @failure_handling : String? = nil,
        @normalizes_line_endings : Bool? = nil,
        @change_annotation_support : ChangeAnnotationSupport? = nil
      )
      end
    end

    class DidChangeConfigurationClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DidChangeWatchedFilesClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      @[JSON::Field(key: "relativePatternSupport")]
      property relative_pattern_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @relative_pattern_support : Bool? = nil)
      end
    end

    class WorkspaceClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "applyEdit")]
      property apply_edit : Bool?
      @[JSON::Field(key: "workspaceEdit")]
      property workspace_edit : WorkspaceEditClientCapabilities | Bool | Nil
      @[JSON::Field(key: "didChangeWatchedFiles")]
      property did_change_watched_files : DidChangeWatchedFilesClientCapabilities | Bool | Nil
      @[JSON::Field(key: "didChangeConfiguration")]
      property did_change_configuration : DidChangeConfigurationClientCapabilities | Bool | Nil
      @[JSON::Field(key: "didChangeWorkspaceFolders")]
      property did_change_workspace_folders : Bool?
      @[JSON::Field(key: "workspaceFolders")]
      property workspace_folders : Bool?
      @[JSON::Field(key: "fileOperations")]
      property file_operations : WorkspaceFileOperationsClientCapabilities?

      def initialize(
        @apply_edit : Bool? = nil,
        @workspace_edit : WorkspaceEditClientCapabilities | Bool | Nil = nil,
        @did_change_watched_files : DidChangeWatchedFilesClientCapabilities | Bool | Nil = nil,
        @did_change_configuration : DidChangeConfigurationClientCapabilities | Bool | Nil = nil,
        @did_change_workspace_folders : Bool? = nil,
        @workspace_folders : Bool? = nil,
        @file_operations : WorkspaceFileOperationsClientCapabilities? = nil
      )
      end
    end

    class TextDocumentSyncClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "willSave")]
      property will_save : Bool?
      @[JSON::Field(key: "willSaveWaitUntil")]
      property will_save_wait_until : Bool?
      @[JSON::Field(key: "didSave")]
      property did_save : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @will_save : Bool? = nil, @will_save_wait_until : Bool? = nil, @did_save : Bool? = nil)
      end
    end

    class CompletionItemTagSupport
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)

      def initialize(@value_set : Array(Int32))
      end
    end

    class CompletionItemResolveSupport
      include JSON::Serializable

      property properties : Array(String)

      def initialize(@properties : Array(String))
      end
    end

    class CompletionItemInsertTextModeSupport
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)

      def initialize(@value_set : Array(Int32))
      end
    end

    class CompletionItemCapabilityOptions
      include JSON::Serializable

      @[JSON::Field(key: "snippetSupport")]
      property snippet_support : Bool?
      @[JSON::Field(key: "commitCharactersSupport")]
      property commit_characters_support : Bool?
      @[JSON::Field(key: "documentationFormat")]
      property documentation_format : Array(MarkupKind)?
      @[JSON::Field(key: "deprecatedSupport")]
      property deprecated_support : Bool?
      @[JSON::Field(key: "preselectSupport")]
      property preselect_support : Bool?
      @[JSON::Field(key: "tagSupport")]
      property tag_support : CompletionItemTagSupport?
      @[JSON::Field(key: "insertReplaceSupport")]
      property insert_replace_support : Bool?
      @[JSON::Field(key: "resolveSupport")]
      property resolve_support : CompletionItemResolveSupport?
      @[JSON::Field(key: "insertTextModeSupport")]
      property insert_text_mode_support : CompletionItemInsertTextModeSupport?
      @[JSON::Field(key: "labelDetailsSupport")]
      property label_details_support : Bool?

      def initialize(
        @snippet_support : Bool? = nil,
        @commit_characters_support : Bool? = nil,
        @documentation_format : Array(MarkupKind)? = nil,
        @deprecated_support : Bool? = nil,
        @preselect_support : Bool? = nil,
        @tag_support : CompletionItemTagSupport? = nil,
        @insert_replace_support : Bool? = nil,
        @resolve_support : CompletionItemResolveSupport? = nil,
        @insert_text_mode_support : CompletionItemInsertTextModeSupport? = nil,
        @label_details_support : Bool? = nil
      )
      end
    end

    class CompletionItemKindClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)?

      def initialize(@value_set : Array(Int32)? = nil)
      end
    end

    class CompletionListCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "itemDefaults")]
      property item_defaults : Array(String)?

      def initialize(@item_defaults : Array(String)? = nil)
      end
    end

    class CompletionClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "completionItem")]
      property completion_item : CompletionItemCapabilityOptions?
      @[JSON::Field(key: "completionItemKind")]
      property completion_item_kind : CompletionItemKindClientCapabilities?
      @[JSON::Field(key: "contextSupport")]
      property context_support : Bool?
      @[JSON::Field(key: "insertTextMode")]
      property insert_text_mode : Int32?
      @[JSON::Field(key: "completionList")]
      property completion_list : CompletionListCapabilities?

      def initialize(@dynamic_registration : Bool? = nil, @completion_item : CompletionItemCapabilityOptions? = nil, @completion_item_kind : CompletionItemKindClientCapabilities? = nil, @context_support : Bool? = nil, @insert_text_mode : Int32? = nil, @completion_list : CompletionListCapabilities? = nil)
      end
    end

    class HoverClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "contentFormat")]
      property content_format : Array(MarkupKind)?

      def initialize(@dynamic_registration : Bool? = nil, @content_format : Array(MarkupKind)? = nil)
      end
    end

    class ParameterInformationCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "labelOffsetSupport")]
      property label_offset_support : Bool?

      def initialize(@label_offset_support : Bool? = nil)
      end
    end

    class SignatureInformationCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "documentationFormat")]
      property documentation_format : Array(MarkupKind)?
      @[JSON::Field(key: "parameterInformation")]
      property parameter_information : ParameterInformationCapabilities?
      @[JSON::Field(key: "activeParameterSupport")]
      property active_parameter_support : Bool?

      def initialize(@documentation_format : Array(MarkupKind)? = nil, @parameter_information : ParameterInformationCapabilities? = nil, @active_parameter_support : Bool? = nil)
      end
    end

    class SignatureHelpClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "signatureInformation")]
      property signature_information : SignatureInformationCapabilities?
      @[JSON::Field(key: "contextSupport")]
      property context_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @signature_information : SignatureInformationCapabilities? = nil, @context_support : Bool? = nil)
      end
    end

    class ReferenceClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DocumentHighlightClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class SymbolKindCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)?

      def initialize(@value_set : Array(Int32)? = nil)
      end
    end

    class SymbolTagSupport
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)

      def initialize(@value_set : Array(Int32))
      end
    end

    class DocumentSymbolClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "symbolKind")]
      property symbol_kind : SymbolKindCapabilities?
      @[JSON::Field(key: "hierarchicalDocumentSymbolSupport")]
      property hierarchical_document_symbol_support : Bool?
      @[JSON::Field(key: "tagSupport")]
      property tag_support : SymbolTagSupport?
      @[JSON::Field(key: "labelSupport")]
      property label_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @symbol_kind : SymbolKindCapabilities? = nil, @hierarchical_document_symbol_support : Bool? = nil, @tag_support : SymbolTagSupport? = nil, @label_support : Bool? = nil)
      end
    end

    class CodeActionLiteralSupport
      include JSON::Serializable

      class CodeActionKindCapabilities
        include JSON::Serializable

        @[JSON::Field(key: "valueSet")]
        property value_set : Array(CodeActionKind)

        def initialize(@value_set : Array(CodeActionKind))
        end
      end

      @[JSON::Field(key: "codeActionKind")]
      property code_action_kind : CodeActionKindCapabilities

      def initialize(@code_action_kind : CodeActionKindCapabilities)
      end
    end

    class CodeActionResolveSupport
      include JSON::Serializable

      property properties : Array(String)

      def initialize(@properties : Array(String))
      end
    end

    class CodeActionClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "codeActionLiteralSupport")]
      property code_action_literal_support : CodeActionLiteralSupport?
      @[JSON::Field(key: "isPreferredSupport")]
      property is_preferred_support : Bool?
      @[JSON::Field(key: "disabledSupport")]
      property disabled_support : Bool?
      @[JSON::Field(key: "dataSupport")]
      property data_support : Bool?
      @[JSON::Field(key: "resolveSupport")]
      property resolve_support : CodeActionResolveSupport?
      @[JSON::Field(key: "honorsChangeAnnotations")]
      property honors_change_annotations : Bool?
      @[JSON::Field(key: "documentationSupport")]
      property documentation_support : Bool?

      def initialize(
        @dynamic_registration : Bool? = nil,
        @code_action_literal_support : CodeActionLiteralSupport? = nil,
        @is_preferred_support : Bool? = nil,
        @disabled_support : Bool? = nil,
        @data_support : Bool? = nil,
        @resolve_support : CodeActionResolveSupport? = nil,
        @honors_change_annotations : Bool? = nil,
        @documentation_support : Bool? = nil
      )
      end
    end

    class CodeLensClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "resolveSupport")]
      property resolve_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @resolve_support : Bool? = nil)
      end
    end

    class DocumentLinkClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "tooltipSupport")]
      property tooltip_support : Bool?
      @[JSON::Field(key: "resolveSupport")]
      property resolve_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @tooltip_support : Bool? = nil, @resolve_support : Bool? = nil)
      end
    end

    class DocumentColorClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DocumentFormattingClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DocumentRangeFormattingClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DocumentOnTypeFormattingClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class RenameClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "prepareSupport")]
      property prepare_support : Bool?
      @[JSON::Field(key: "prepareSupportDefaultBehavior")]
      property prepare_support_default_behavior : Int32?
      @[JSON::Field(key: "honorsChangeAnnotations")]
      property honors_change_annotations : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @prepare_support : Bool? = nil, @prepare_support_default_behavior : Int32? = nil, @honors_change_annotations : Bool? = nil)
      end
    end

    class FoldingRangeKindCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(String)?

      def initialize(@value_set : Array(String)? = nil)
      end
    end

    class FoldingRangeCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "collapsedText")]
      property collapsed_text : Bool?

      def initialize(@collapsed_text : Bool? = nil)
      end
    end

    class FoldingRangeClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "rangeLimit")]
      property range_limit : Int32?
      @[JSON::Field(key: "lineFoldingOnly")]
      property line_folding_only : Bool?
      @[JSON::Field(key: "foldingRangeKind")]
      property folding_range_kind : FoldingRangeKindCapabilities?
      @[JSON::Field(key: "foldingRange")]
      property folding_range : FoldingRangeCapabilities?

      def initialize(@dynamic_registration : Bool? = nil, @range_limit : Int32? = nil, @line_folding_only : Bool? = nil, @folding_range_kind : FoldingRangeKindCapabilities? = nil, @folding_range : FoldingRangeCapabilities? = nil)
      end
    end

    class SelectionRangeClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class CallHierarchyClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class TypeHierarchyClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class SemanticTokensRequestsFull
      include JSON::Serializable

      property delta : Bool?

      def initialize(@delta : Bool? = nil)
      end
    end

    class SemanticTokensRequests
      include JSON::Serializable

      property range : Bool | Nil
      property full : Bool | SemanticTokensRequestsFull | Nil

      def initialize(@range : Bool | Nil = nil, @full : Bool | SemanticTokensRequestsFull | Nil = nil)
      end
    end

    class SemanticTokensClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      property requests : SemanticTokensRequests
      @[JSON::Field(key: "tokenTypes")]
      property token_types : Array(String)
      @[JSON::Field(key: "tokenModifiers")]
      property token_modifiers : Array(String)
      property formats : Array(String)
      @[JSON::Field(key: "overlappingTokenSupport")]
      property overlapping_token_support : Bool?
      @[JSON::Field(key: "multilineTokenSupport")]
      property multiline_token_support : Bool?
      @[JSON::Field(key: "serverCancelSupport")]
      property server_cancel_support : Bool?
      @[JSON::Field(key: "augmentsSyntaxTokens")]
      property augments_syntax_tokens : Bool?

      def initialize(@requests : SemanticTokensRequests, @token_types : Array(String), @token_modifiers : Array(String), @formats : Array(String), @dynamic_registration : Bool? = nil, @overlapping_token_support : Bool? = nil, @multiline_token_support : Bool? = nil, @server_cancel_support : Bool? = nil, @augments_syntax_tokens : Bool? = nil)
      end
    end

    class LinkedEditingRangeClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class MonikerClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class InlayHintResolveSupport
      include JSON::Serializable

      property properties : Array(String)

      def initialize(@properties : Array(String))
      end
    end

    class InlayHintClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "resolveSupport")]
      property resolve_support : InlayHintResolveSupport?
      @[JSON::Field(key: "honorsChangeAnnotations")]
      property honors_change_annotations : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @resolve_support : InlayHintResolveSupport? = nil, @honors_change_annotations : Bool? = nil)
      end
    end

    class InlineValueClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?

      def initialize(@dynamic_registration : Bool? = nil)
      end
    end

    class DiagnosticClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "dynamicRegistration")]
      property dynamic_registration : Bool?
      @[JSON::Field(key: "relatedDocumentSupport")]
      property related_document_support : Bool?

      def initialize(@dynamic_registration : Bool? = nil, @related_document_support : Bool? = nil)
      end
    end

    class PublishDiagnosticsTagSupport
      include JSON::Serializable

      @[JSON::Field(key: "valueSet")]
      property value_set : Array(Int32)

      def initialize(@value_set : Array(Int32))
      end
    end

    class PublishDiagnosticsClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "relatedInformation")]
      property related_information : Bool?
      @[JSON::Field(key: "tagSupport")]
      property tag_support : PublishDiagnosticsTagSupport?
      @[JSON::Field(key: "versionSupport")]
      property version_support : Bool?
      @[JSON::Field(key: "codeDescriptionSupport")]
      property code_description_support : Bool?
      @[JSON::Field(key: "dataSupport")]
      property data_support : Bool?
      @[JSON::Field(key: "relatedDocumentSupport")]
      property related_document_support : Bool?

      def initialize(@related_information : Bool? = nil, @tag_support : PublishDiagnosticsTagSupport? = nil, @version_support : Bool? = nil, @code_description_support : Bool? = nil, @data_support : Bool? = nil, @related_document_support : Bool? = nil)
      end
    end

    class TextDocumentClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "synchronization")]
      property synchronization : TextDocumentSyncClientCapabilities | Bool | Nil
      property completion : CompletionClientCapabilities | Bool | Nil
      property hover : HoverClientCapabilities | Bool | Nil
      @[JSON::Field(key: "signatureHelp")]
      property signature_help : SignatureHelpClientCapabilities | Bool | Nil
      property references : ReferenceClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentHighlight")]
      property document_highlight : DocumentHighlightClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentSymbol")]
      property document_symbol : DocumentSymbolClientCapabilities | Bool | Nil
      @[JSON::Field(key: "codeAction")]
      property code_action : CodeActionClientCapabilities | Bool | Nil
      @[JSON::Field(key: "codeLens")]
      property code_lens : CodeLensClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentFormatting")]
      property document_formatting : DocumentFormattingClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentRangeFormatting")]
      property document_range_formatting : DocumentRangeFormattingClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentOnTypeFormatting")]
      property document_on_type_formatting : DocumentOnTypeFormattingClientCapabilities | Bool | Nil
      property rename : RenameClientCapabilities | Bool | Nil
      @[JSON::Field(key: "documentLink")]
      property document_link : DocumentLinkClientCapabilities | Bool | Nil
      @[JSON::Field(key: "colorProvider")]
      property color_provider : DocumentColorClientCapabilities | Bool | Nil
      @[JSON::Field(key: "foldingRange")]
      property folding_range : FoldingRangeClientCapabilities | Bool | Nil
      @[JSON::Field(key: "selectionRange")]
      property selection_range : SelectionRangeClientCapabilities | Bool | Nil
      @[JSON::Field(key: "callHierarchy")]
      property call_hierarchy : CallHierarchyClientCapabilities | Bool | Nil
      @[JSON::Field(key: "semanticTokens")]
      property semantic_tokens : SemanticTokensClientCapabilities | Bool | Nil
      @[JSON::Field(key: "linkedEditingRange")]
      property linked_editing_range : LinkedEditingRangeClientCapabilities | Bool | Nil
      property moniker : MonikerClientCapabilities | Bool | Nil
      @[JSON::Field(key: "inlayHint")]
      property inlay_hint : InlayHintClientCapabilities | Bool | Nil
      @[JSON::Field(key: "inlineValue")]
      property inline_value : InlineValueClientCapabilities | Bool | Nil
      property diagnostic : DiagnosticClientCapabilities | Bool | Nil
      @[JSON::Field(key: "publishDiagnostics")]
      property publish_diagnostics : PublishDiagnosticsClientCapabilities?
      @[JSON::Field(key: "typeHierarchy")]
      property type_hierarchy : TypeHierarchyClientCapabilities | Bool | Nil

      def initialize(
        @synchronization : TextDocumentSyncClientCapabilities | Bool | Nil = nil,
        @completion : CompletionClientCapabilities | Bool | Nil = nil,
        @hover : HoverClientCapabilities | Bool | Nil = nil,
        @signature_help : SignatureHelpClientCapabilities | Bool | Nil = nil,
        @references : ReferenceClientCapabilities | Bool | Nil = nil,
        @document_highlight : DocumentHighlightClientCapabilities | Bool | Nil = nil,
        @document_symbol : DocumentSymbolClientCapabilities | Bool | Nil = nil,
        @code_action : CodeActionClientCapabilities | Bool | Nil = nil,
        @code_lens : CodeLensClientCapabilities | Bool | Nil = nil,
        @document_formatting : DocumentFormattingClientCapabilities | Bool | Nil = nil,
        @document_range_formatting : DocumentRangeFormattingClientCapabilities | Bool | Nil = nil,
        @document_on_type_formatting : DocumentOnTypeFormattingClientCapabilities | Bool | Nil = nil,
        @rename : RenameClientCapabilities | Bool | Nil = nil,
        @document_link : DocumentLinkClientCapabilities | Bool | Nil = nil,
        @color_provider : DocumentColorClientCapabilities | Bool | Nil = nil,
        @folding_range : FoldingRangeClientCapabilities | Bool | Nil = nil,
        @selection_range : SelectionRangeClientCapabilities | Bool | Nil = nil,
        @call_hierarchy : CallHierarchyClientCapabilities | Bool | Nil = nil,
        @semantic_tokens : SemanticTokensClientCapabilities | Bool | Nil = nil,
        @linked_editing_range : LinkedEditingRangeClientCapabilities | Bool | Nil = nil,
        @moniker : MonikerClientCapabilities | Bool | Nil = nil,
        @inlay_hint : InlayHintClientCapabilities | Bool | Nil = nil,
        @inline_value : InlineValueClientCapabilities | Bool | Nil = nil,
        @diagnostic : DiagnosticClientCapabilities | Bool | Nil = nil,
        @publish_diagnostics : PublishDiagnosticsClientCapabilities? = nil,
        @type_hierarchy : TypeHierarchyClientCapabilities | Bool | Nil = nil
      )
      end
    end

    class ShowMessageRequestClientCapabilities
      include JSON::Serializable

      class MessageActionItemCapabilities
        include JSON::Serializable

        @[JSON::Field(key: "additionalPropertiesSupport")]
        property additional_properties_support : Bool?

        def initialize(@additional_properties_support : Bool? = nil)
        end
      end

      @[JSON::Field(key: "messageActionItem")]
      property message_action_item : MessageActionItemCapabilities?

      def initialize(@message_action_item : MessageActionItemCapabilities? = nil)
      end
    end

    class ShowDocumentClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "support")]
      property support : Bool?

      def initialize(@support : Bool? = nil)
      end
    end

    class WindowClientCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool?
      @[JSON::Field(key: "showMessage")]
      property show_message : ShowMessageRequestClientCapabilities?
      @[JSON::Field(key: "showDocument")]
      property show_document : ShowDocumentClientCapabilities?

      def initialize(@work_done_progress : Bool? = nil, @show_message : ShowMessageRequestClientCapabilities? = nil, @show_document : ShowDocumentClientCapabilities? = nil)
      end
    end

    class ClientCapabilities
      include JSON::Serializable

      property workspace : WorkspaceClientCapabilities?
      @[JSON::Field(key: "textDocument")]
      property text_document : TextDocumentClientCapabilities?
      property notebook : JSON::Any?
      property window : WindowClientCapabilities?
      property general : JSON::Any?
      property experimental : JSON::Any?

      def initialize(@workspace : WorkspaceClientCapabilities? = nil, @text_document : TextDocumentClientCapabilities? = nil, @notebook : JSON::Any? = nil, @window : WindowClientCapabilities? = nil, @general : JSON::Any? = nil, @experimental : JSON::Any? = nil)
      end
    end

    # ---- Server capabilities ----

    class CompletionOptions
      include JSON::Serializable

      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = false

      @[JSON::Field(key: "triggerCharacters")]
      property trigger_characters : Array(String)?

      @[JSON::Field(key: "allCommitCharacters")]
      property all_commit_characters : Array(String)?

      def initialize(@resolve_provider : Bool? = false, @trigger_characters : Array(String)? = nil, @all_commit_characters : Array(String)? = nil)
      end
    end

    class CodeActionOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil
      @[JSON::Field(key: "codeActionKinds")]
      property code_action_kinds : Array(String)?
      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil, @code_action_kinds : Array(String)? = nil, @resolve_provider : Bool? = nil)
      end
    end

    class CodeActionContext
      include JSON::Serializable

      property diagnostics : Array(Diagnostic)
      property only : Array(CodeActionKind)?
      @[JSON::Field(key: "triggerKind")]
      property trigger_kind : CodeActionTriggerKind?

      def initialize(@diagnostics : Array(Diagnostic), @only : Array(CodeActionKind)? = nil, @trigger_kind : CodeActionTriggerKind? = nil)
      end
    end

    alias CodeActionKind = String

    enum CodeActionTriggerKind : Int32
      Invoked = 1
      Automatic = 2
    end

    class CodeActionDisabled
      include JSON::Serializable

      property reason : String

      def initialize(@reason : String)
      end
    end

    enum CodeActionTag : Int32
      LLMGenerated = 1
    end

    class CodeAction
      include JSON::Serializable

      property title : String
      property kind : CodeActionKind?
      property diagnostics : Array(Diagnostic)?
      @[JSON::Field(key: "isPreferred")]
      property is_preferred : Bool?
      property disabled : CodeActionDisabled?
      property edit : WorkspaceEdit?
      property command : Command?
      property data : JSON::Any?
      property tags : Array(CodeActionTag)?

      def initialize(@title : String, @kind : CodeActionKind? = nil, @diagnostics : Array(Diagnostic)? = nil, @is_preferred : Bool? = nil, @disabled : CodeActionDisabled? = nil, @edit : WorkspaceEdit? = nil, @command : Command? = nil, @data : JSON::Any? = nil, @tags : Array(CodeActionTag)? = nil)
      end
    end

    class CodeLens
      include JSON::Serializable

      property range : Range
      property command : Command?
      property data : JSON::Any?

      def initialize(@range : Range, @command : Command? = nil, @data : JSON::Any? = nil)
      end
    end

    class CodeLensOptions
      include JSON::Serializable

      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = nil
      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@resolve_provider : Bool? = nil, @work_done_progress : Bool? = nil)
      end
    end

    class DocumentOnTypeFormattingOptions
      include JSON::Serializable

      @[JSON::Field(key: "firstTriggerCharacter")]
      property first_trigger_character : String
      @[JSON::Field(key: "moreTriggerCharacter")]
      property more_trigger_character : Array(String)?

      def initialize(@first_trigger_character : String, @more_trigger_character : Array(String)? = nil)
      end
    end

    class ExecuteCommandOptions
      include JSON::Serializable

      property commands : Array(String)
      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@commands : Array(String), @work_done_progress : Bool? = nil)
      end
    end

    class SelectionRangeOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class FoldingRangeOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class CallHierarchyOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class LinkedEditingRangeOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class MonikerOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class DocumentColorOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class SemanticTokensLegend
      include JSON::Serializable

      @[JSON::Field(key: "tokenTypes")]
      property token_types : Array(String)
      @[JSON::Field(key: "tokenModifiers")]
      property token_modifiers : Array(String)

      def initialize(@token_types : Array(String), @token_modifiers : Array(String))
      end
    end

    class SemanticTokensFullOptions
      include JSON::Serializable

      property delta : Bool? = nil

      def initialize(@delta : Bool? = nil)
      end
    end

    class SemanticTokensOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      property legend : SemanticTokensLegend
      property range : Bool | Nil
      property full : Bool | SemanticTokensFullOptions | Nil

      def initialize(@legend : SemanticTokensLegend, @range : Bool | Nil = nil, @full : Bool | SemanticTokensFullOptions | Nil = nil, @work_done_progress : Bool? = nil)
      end
    end

    class SemanticTokens
      include JSON::Serializable

      @[JSON::Field(key: "resultId")]
      property result_id : String?
      property data : Array(Int32)

      def initialize(@data : Array(Int32), @result_id : String? = nil)
      end
    end

    class SemanticTokensEdit
      include JSON::Serializable

      property start : Int32
      @[JSON::Field(key: "deleteCount")]
      property delete_count : Int32
      property data : Array(Int32)?

      def initialize(@start : Int32, @delete_count : Int32, @data : Array(Int32)? = nil)
      end
    end

    class SemanticTokensDelta
      include JSON::Serializable

      @[JSON::Field(key: "resultId")]
      property result_id : String?
      property edits : Array(SemanticTokensEdit)

      def initialize(@edits : Array(SemanticTokensEdit), @result_id : String? = nil)
      end
    end

    class InlayHintOptions
      include JSON::Serializable

      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = nil
      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@resolve_provider : Bool? = nil, @work_done_progress : Bool? = nil)
      end
    end

    class InlineValueOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class DiagnosticOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil
      @[JSON::Field(key: "interFileDependencies")]
      property inter_file_dependencies : Bool? = nil
      @[JSON::Field(key: "workspaceDiagnostics")]
      property workspace_diagnostics : Bool? = nil

      @[JSON::Field(key: "identifier")]
      property identifier : String?

      def initialize(@work_done_progress : Bool? = nil, @inter_file_dependencies : Bool? = nil, @workspace_diagnostics : Bool? = nil, @identifier : String? = nil)
      end
    end

    # ---- Diagnostics pull ----

    enum DocumentDiagnosticReportKind
      Full
      Unchanged
    end

    class DocumentDiagnosticReportBase
      include JSON::Serializable

      property kind : DocumentDiagnosticReportKind
      @[JSON::Field(key: "resultId")]
      property result_id : String?
      @[JSON::Field(key: "relatedDocuments")]
      property related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)?

      def initialize(@kind : DocumentDiagnosticReportKind, @result_id : String? = nil, @related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
      end
    end

    class DocumentDiagnosticReportFull < DocumentDiagnosticReportBase
      include JSON::Serializable

      property items : Array(Diagnostic)

      def initialize(@items : Array(Diagnostic), result_id : String? = nil, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(DocumentDiagnosticReportKind::Full, result_id, related_documents)
      end
    end

    class DocumentDiagnosticReportUnchanged < DocumentDiagnosticReportBase
      include JSON::Serializable

      def initialize(result_id : String, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(DocumentDiagnosticReportKind::Unchanged, result_id, related_documents)
      end
    end

    class RelatedFullDocumentDiagnosticReport < DocumentDiagnosticReportFull
      include JSON::Serializable

      property uri : DocumentUri
      property version : Int32?

      def initialize(@uri : DocumentUri, @version : Int32?, items : Array(Diagnostic), result_id : String? = nil, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(items, result_id, related_documents)
      end
    end

    class RelatedUnchangedDocumentDiagnosticReport < DocumentDiagnosticReportUnchanged
      include JSON::Serializable

      property uri : DocumentUri
      property version : Int32?

      def initialize(@uri : DocumentUri, @version : Int32?, result_id : String, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(result_id, related_documents)
      end
    end

    alias RelatedDocumentDiagnosticReport = RelatedFullDocumentDiagnosticReport | RelatedUnchangedDocumentDiagnosticReport

    alias DocumentDiagnosticReport = DocumentDiagnosticReportFull | DocumentDiagnosticReportUnchanged

    class DocumentDiagnosticParams
      include JSON::Serializable

      @[JSON::Field(key: "textDocument")]
      property text_document : TextDocumentIdentifier
      property identifier : String?
      @[JSON::Field(key: "previousResultId")]
      property previous_result_id : String?
      @[JSON::Field(key: "workDoneToken")]
      property work_done_token : ProgressToken?
      @[JSON::Field(key: "partialResultToken")]
      property partial_result_token : ProgressToken?

      def initialize(@text_document : TextDocumentIdentifier, @identifier : String? = nil, @previous_result_id : String? = nil, @work_done_token : ProgressToken? = nil, @partial_result_token : ProgressToken? = nil)
      end
    end

    class PreviousResultId
      include JSON::Serializable

      property uri : DocumentUri
      property value : String

      def initialize(@uri : DocumentUri, @value : String)
      end
    end

    class WorkspaceDocumentDiagnosticReportBase < DocumentDiagnosticReportBase
      include JSON::Serializable

      property uri : DocumentUri
      property version : Int32?

      def initialize(@uri : DocumentUri, @version : Int32?, kind : DocumentDiagnosticReportKind, result_id : String? = nil, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(kind, result_id, related_documents)
      end
    end

    class WorkspaceFullDocumentDiagnosticReport < WorkspaceDocumentDiagnosticReportBase
      include JSON::Serializable

      property items : Array(Diagnostic)

      def initialize(uri : DocumentUri, version : Int32?, @items : Array(Diagnostic), result_id : String? = nil, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(uri, version, DocumentDiagnosticReportKind::Full, result_id, related_documents)
      end
    end

    class WorkspaceUnchangedDocumentDiagnosticReport < WorkspaceDocumentDiagnosticReportBase
      include JSON::Serializable

      def initialize(uri : DocumentUri, version : Int32?, result_id : String, related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
        super(uri, version, DocumentDiagnosticReportKind::Unchanged, result_id, related_documents)
      end
    end

    alias WorkspaceDocumentDiagnosticReport = WorkspaceFullDocumentDiagnosticReport | WorkspaceUnchangedDocumentDiagnosticReport

    class WorkspaceDiagnosticReport
      include JSON::Serializable

      property items : Array(WorkspaceDocumentDiagnosticReport)
      @[JSON::Field(key: "relatedDocuments")]
      property related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)?

      def initialize(@items : Array(WorkspaceDocumentDiagnosticReport), @related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
      end
    end

    class WorkspaceDiagnosticParams
      include JSON::Serializable

      property identifier : String?
      @[JSON::Field(key: "previousResultIds")]
      property previous_result_ids : Array(PreviousResultId)?
      @[JSON::Field(key: "workDoneToken")]
      property work_done_token : ProgressToken?
      @[JSON::Field(key: "partialResultToken")]
      property partial_result_token : ProgressToken?

      def initialize(@identifier : String? = nil, @previous_result_ids : Array(PreviousResultId)? = nil, @work_done_token : ProgressToken? = nil, @partial_result_token : ProgressToken? = nil)
      end
    end

    class DocumentDiagnosticReportPartialResult
      include JSON::Serializable

      @[JSON::Field(key: "relatedDocuments")]
      property related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)?

      def initialize(@related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
      end
    end

    class WorkspaceDiagnosticReportPartialResult
      include JSON::Serializable

      property items : Array(WorkspaceDocumentDiagnosticReport)?
      @[JSON::Field(key: "relatedDocuments")]
      property related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)?

      def initialize(@items : Array(WorkspaceDocumentDiagnosticReport)? = nil, @related_documents : Hash(DocumentUri, RelatedDocumentDiagnosticReport)? = nil)
      end
    end

    class HoverOptions
      include JSON::Serializable

      @[JSON::Field(key: "workDoneProgress")]
      property work_done_progress : Bool? = nil

      def initialize(@work_done_progress : Bool? = nil)
      end
    end

    class SignatureHelpOptions
      include JSON::Serializable

      @[JSON::Field(key: "triggerCharacters")]
      property trigger_characters : Array(String)?

      @[JSON::Field(key: "retriggerCharacters")]
      property retrigger_characters : Array(String)?

      def initialize(@trigger_characters : Array(String)? = nil, @retrigger_characters : Array(String)? = nil)
      end
    end

    class RenameOptions
      include JSON::Serializable

      @[JSON::Field(key: "prepareProvider")]
      property prepare_provider : Bool? = nil

      def initialize(@prepare_provider : Bool? = nil)
      end
    end

    class DocumentLinkOptions
      include JSON::Serializable

      @[JSON::Field(key: "resolveProvider")]
      property resolve_provider : Bool? = nil

      def initialize(@resolve_provider : Bool? = nil)
      end
    end

    class ServerCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "textDocumentSync")]
      property text_document_sync : TextDocumentSyncOptions | TextDocumentSyncKind | Nil
      @[JSON::Field(key: "completionProvider")]
      property completion_provider : CompletionOptions?
      @[JSON::Field(key: "hoverProvider")]
      property hover_provider : Bool | HoverOptions | Nil
      @[JSON::Field(key: "definitionProvider")]
      property definition_provider : Bool?
      @[JSON::Field(key: "referencesProvider")]
      property references_provider : Bool?
      @[JSON::Field(key: "documentSymbolProvider")]
      property document_symbol_provider : Bool?
      @[JSON::Field(key: "workspaceSymbolProvider")]
      property workspace_symbol_provider : Bool?
      @[JSON::Field(key: "typeDefinitionProvider")]
      property type_definition_provider : Bool?
      @[JSON::Field(key: "implementationProvider")]
      property implementation_provider : Bool?
      @[JSON::Field(key: "signatureHelpProvider")]
      property signature_help_provider : SignatureHelpOptions?
      @[JSON::Field(key: "documentFormattingProvider")]
      property document_formatting_provider : Bool?
      @[JSON::Field(key: "documentRangeFormattingProvider")]
      property document_range_formatting_provider : Bool?
      @[JSON::Field(key: "renameProvider")]
      property rename_provider : Bool | RenameOptions | Nil
      @[JSON::Field(key: "documentLinkProvider")]
      property document_link_provider : DocumentLinkOptions?
      @[JSON::Field(key: "codeActionProvider")]
      property code_action_provider : Bool | CodeActionOptions | Nil
      @[JSON::Field(key: "codeLensProvider")]
      property code_lens_provider : CodeLensOptions?
      @[JSON::Field(key: "documentOnTypeFormattingProvider")]
      property document_on_type_formatting_provider : DocumentOnTypeFormattingOptions?
      @[JSON::Field(key: "executeCommandProvider")]
      property execute_command_provider : ExecuteCommandOptions?
      @[JSON::Field(key: "selectionRangeProvider")]
      property selection_range_provider : Bool | SelectionRangeOptions | Nil
      @[JSON::Field(key: "foldingRangeProvider")]
      property folding_range_provider : Bool | FoldingRangeOptions | Nil
      @[JSON::Field(key: "callHierarchyProvider")]
      property call_hierarchy_provider : Bool | CallHierarchyOptions | Nil
      @[JSON::Field(key: "semanticTokensProvider")]
      property semantic_tokens_provider : SemanticTokensOptions | Bool | Nil
      @[JSON::Field(key: "inlayHintProvider")]
      property inlay_hint_provider : Bool | InlayHintOptions | Nil
      @[JSON::Field(key: "inlineValueProvider")]
      property inline_value_provider : Bool | InlineValueOptions | Nil
      @[JSON::Field(key: "diagnosticProvider")]
      property diagnostic_provider : Bool | DiagnosticOptions | Nil
      @[JSON::Field(key: "linkedEditingRangeProvider")]
      property linked_editing_range_provider : Bool | LinkedEditingRangeOptions | Nil
      @[JSON::Field(key: "monikerProvider")]
      property moniker_provider : Bool | MonikerOptions | Nil
      @[JSON::Field(key: "colorProvider")]
      property color_provider : Bool | DocumentColorOptions | Nil
      property workspace : WorkspaceServerCapabilities?
      @[JSON::Field(key: "positionEncoding")]
      property position_encoding : String?
      @[JSON::Field(key: "experimental")]
      property experimental : JSON::Any?

      def initialize(@text_document_sync : TextDocumentSyncOptions | TextDocumentSyncKind | Nil = nil,
                     @completion_provider : CompletionOptions? = nil,
                     @hover_provider : Bool | HoverOptions | Nil = nil,
                     @definition_provider : Bool? = nil,
                     @references_provider : Bool? = nil,
                     @document_symbol_provider : Bool? = nil,
                     @workspace_symbol_provider : Bool? = nil,
                     @type_definition_provider : Bool? = nil,
                     @implementation_provider : Bool? = nil,
                     @signature_help_provider : SignatureHelpOptions? = nil,
                     @document_formatting_provider : Bool? = nil,
                     @document_range_formatting_provider : Bool? = nil,
                     @rename_provider : Bool | RenameOptions | Nil = nil,
                     @document_link_provider : DocumentLinkOptions? = nil,
                     @code_action_provider : Bool | CodeActionOptions | Nil = nil,
                     @code_lens_provider : CodeLensOptions? = nil,
                     @document_on_type_formatting_provider : DocumentOnTypeFormattingOptions? = nil,
                     @execute_command_provider : ExecuteCommandOptions? = nil,
                     @selection_range_provider : Bool | SelectionRangeOptions | Nil = nil,
                     @folding_range_provider : Bool | FoldingRangeOptions | Nil = nil,
                     @call_hierarchy_provider : Bool | CallHierarchyOptions | Nil = nil,
                     @semantic_tokens_provider : SemanticTokensOptions | Bool | Nil = nil,
                     @inlay_hint_provider : Bool | InlayHintOptions | Nil = nil,
                     @inline_value_provider : Bool | InlineValueOptions | Nil = nil,
                     @diagnostic_provider : Bool | DiagnosticOptions | Nil = nil,
                     @linked_editing_range_provider : Bool | LinkedEditingRangeOptions | Nil = nil,
                     @moniker_provider : Bool | MonikerOptions | Nil = nil,
                     @color_provider : Bool | DocumentColorOptions | Nil = nil,
                     @workspace : WorkspaceServerCapabilities? = nil,
                     @position_encoding : String? = nil,
                     @experimental : JSON::Any? = nil)
      end
    end

    class WorkspaceServerCapabilities
      include JSON::Serializable

      @[JSON::Field(key: "fileOperations")]
      property file_operations : FileOperationOptions?

      def initialize(@file_operations : FileOperationOptions? = nil)
      end
    end

    class InitializeResult
      include JSON::Serializable

      property capabilities : ServerCapabilities
      @[JSON::Field(key: "serverInfo")]
      property server_info : ServerInfo?

      def initialize(@capabilities : ServerCapabilities, @server_info : ServerInfo? = nil)
      end
    end

    # ---- Completion ----

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

    enum InsertTextMode : Int32
      AsIs = 1
      AdjustIndentation = 2
    end

    enum CompletionItemTag : Int32
      Deprecated = 1
    end

    enum ApplyKind : Int32
      Replace = 1
      Merge = 2
    end

    class InsertReplaceEdit
      include JSON::Serializable

      @[JSON::Field(key: "newText")]
      property new_text : String
      property insert : Range
      property replace : Range

      def initialize(@new_text : String, @insert : Range, @replace : Range)
      end
    end

    class CompletionItemLabelDetails
      include JSON::Serializable

      property detail : String?
      property description : String?

      def initialize(@detail : String? = nil, @description : String? = nil)
      end
    end

    class EditRangeWithInsertReplace
      include JSON::Serializable

      property insert : Range
      property replace : Range

      def initialize(@insert : Range, @replace : Range)
      end
    end

    class CompletionItemDefaults
      include JSON::Serializable

      @[JSON::Field(key: "commitCharacters")]
      property commit_characters : Array(String)?
      @[JSON::Field(key: "editRange")]
      property edit_range : Range | EditRangeWithInsertReplace | Nil
      @[JSON::Field(key: "insertTextFormat")]
      property insert_text_format : InsertTextFormat?
      @[JSON::Field(key: "insertTextMode")]
      property insert_text_mode : InsertTextMode?
      property data : JSON::Any?

      def initialize(@commit_characters : Array(String)? = nil, @edit_range : Range | EditRangeWithInsertReplace | Nil = nil, @insert_text_format : InsertTextFormat? = nil, @insert_text_mode : InsertTextMode? = nil, @data : JSON::Any? = nil)
      end
    end

    class CompletionItemApplyKinds
      include JSON::Serializable

      @[JSON::Field(key: "commitCharacters")]
      property commit_characters : ApplyKind?
      property data : ApplyKind?

      def initialize(@commit_characters : ApplyKind? = nil, @data : ApplyKind? = nil)
      end
    end

    class CompletionContext
      include JSON::Serializable

      @[JSON::Field(key: "triggerKind", converter: ::CRA::Types::CompletionTriggerKindConverter)]
      property trigger_kind : CompletionTriggerKind

      @[JSON::Field(key: "triggerCharacter")]
      property trigger_character : String?

      def initialize(@trigger_kind : CompletionTriggerKind, @trigger_character : String? = nil)
      end
    end

    class CompletionItem
      include JSON::Serializable

      property label : String
      @[JSON::Field(key: "labelDetails")]
      property label_details : CompletionItemLabelDetails?
      @[JSON::Field(converter: ::CRA::Types::CompletionItemKindConverter)]
      property kind : CompletionItemKind?
      property tags : Array(CompletionItemTag)?
      property detail : String?
      property documentation : JSON::Any?
      property deprecated : Bool?
      property preselect : Bool?
      @[JSON::Field(key: "sortText")]
      property sort_text : String?
      @[JSON::Field(key: "filterText")]
      property filter_text : String?

      @[JSON::Field(key: "insertText")]
      property insert_text : String?

      @[JSON::Field(key: "insertTextFormat")]
      property insert_text_format : InsertTextFormat?

      @[JSON::Field(key: "insertTextMode")]
      property insert_text_mode : InsertTextMode?

      @[JSON::Field(key: "textEdit")]
      property text_edit : TextEdit | InsertReplaceEdit | Nil

      @[JSON::Field(key: "textEditText")]
      property text_edit_text : String?

      @[JSON::Field(key: "additionalTextEdits")]
      property additional_text_edits : TextEdits?

      @[JSON::Field(key: "commitCharacters")]
      property commit_characters : Array(String)?

      property command : Command?

      property data : JSON::Any?

      def initialize(
        @label : String,
        @label_details : CompletionItemLabelDetails? = nil,
        @kind : CompletionItemKind? = nil,
        @tags : Array(CompletionItemTag)? = nil,
        @detail : String? = nil,
        @documentation : JSON::Any? = nil,
        @deprecated : Bool? = nil,
        @preselect : Bool? = nil,
        @sort_text : String? = nil,
        @filter_text : String? = nil,
        @insert_text : String? = nil,
        @insert_text_format : InsertTextFormat? = nil,
        @insert_text_mode : InsertTextMode? = nil,
        @text_edit : TextEdit | InsertReplaceEdit | Nil = nil,
        @text_edit_text : String? = nil,
        @additional_text_edits : TextEdits? = nil,
        @commit_characters : Array(String)? = nil,
        @command : Command? = nil,
        @data : JSON::Any? = nil
      )
      end
    end

    class CompletionList
      include JSON::Serializable

      @[JSON::Field(key: "isIncomplete")]
      property is_incomplete : Bool = false

      @[JSON::Field(key: "itemDefaults")]
      property item_defaults : CompletionItemDefaults?

      @[JSON::Field(key: "applyKind")]
      property apply_kind : CompletionItemApplyKinds?

      property items : Array(CompletionItem)

      def initialize(@items : Array(CompletionItem), @is_incomplete : Bool = false, @item_defaults : CompletionItemDefaults? = nil, @apply_kind : CompletionItemApplyKinds? = nil)
      end
    end

    # ---- Hover ----

    enum MarkupKind
      PlainText
      Markdown
    end

    class MarkupContent
      include JSON::Serializable

      property kind : MarkupKind
      property value : String

      def initialize(@kind : MarkupKind, @value : String)
      end
    end

    class Hover
      include JSON::Serializable

      # Accept MarkupContent, MarkedString, MarkedString[]; use JSON::Any to cover variants.
      property contents : JSON::Any
      property range : Range?

      def initialize(@contents : JSON::Any, @range : Range? = nil)
      end
    end

    # ---- Signature help ----

    class ParameterInformation
      include JSON::Serializable

      # Label may be string or tuple; store as JSON::Any to support both.
      property label : JSON::Any
      property documentation : JSON::Any?

      def initialize(@label : JSON::Any, @documentation : JSON::Any? = nil)
      end
    end

    class SignatureInformation
      include JSON::Serializable

      property label : String
      property documentation : JSON::Any?
      property parameters : Array(ParameterInformation)?

      def initialize(@label : String, @documentation : JSON::Any? = nil, @parameters : Array(ParameterInformation)? = nil)
      end
    end

    class SignatureHelp
      include JSON::Serializable

      property signatures : Array(SignatureInformation)
      @[JSON::Field(key: "activeSignature")]
      property active_signature : Int32?
      @[JSON::Field(key: "activeParameter")]
      property active_parameter : Int32?

      def initialize(@signatures : Array(SignatureInformation), @active_signature : Int32? = nil, @active_parameter : Int32? = nil)
      end
    end

    # ---- Symbols ----

    enum SymbolKind : Int32
      File = 1
      Module = 2
      Namespace = 3
      Package = 4
      Class = 5
      Method = 6
      Property = 7
      Field = 8
      Constructor = 9
      Enum = 10
      Interface = 11
      Function = 12
      Variable = 13
      Constant = 14
      String = 15
      Number = 16
      Boolean = 17
      Array = 18
      Object = 19
      Key = 20
      Null = 21
      EnumMember = 22
      Struct = 23
      Event = 24
      Operator = 25
      TypeParameter = 26
    end

    enum SymbolTag : Int32
      Deprecated = 1
    end

    class SymbolInformation
      include JSON::Serializable

      property name : String
      property kind : SymbolKind
      property tags : Array(SymbolTag)?
      property location : Location
      @[JSON::Field(key: "containerName")]
      property container_name : String?

      def initialize(@name : String, @kind : SymbolKind, @location : Location, @container_name : String? = nil, @tags : Array(SymbolTag)? = nil)
      end
    end

    class DocumentSymbol
      include JSON::Serializable

      property name : String
      property detail : String?
      property kind : SymbolKind
      property tags : Array(SymbolTag)?
      @[JSON::Field(key: "deprecated")]
      property deprecated : Bool?
      property range : Range
      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range
      property children : DocumentSymbols?

      def initialize(
        @name : String,
        @kind : SymbolKind,
        @range : Range,
        @selection_range : Range,
        @detail : String? = nil,
        @tags : Array(SymbolTag)? = nil,
        @deprecated : Bool? = nil,
        @children : DocumentSymbols? = nil
      )
      end
    end

    enum DocumentHighlightKind : Int32
      Text = 1
      Read = 2
      Write = 3
    end

    class DocumentHighlight
      include JSON::Serializable

      property range : Range
      property kind : DocumentHighlightKind?

      def initialize(@range : Range, @kind : DocumentHighlightKind? = nil)
      end
    end

    class SelectionRange
      include JSON::Serializable

      property range : Range
      property parent : SelectionRange?

      def initialize(@range : Range, @parent : SelectionRange? = nil)
      end
    end

    class CallHierarchyItem
      include JSON::Serializable

      property name : String
      property kind : SymbolKind
      property tags : Array(SymbolTag)?
      property detail : String?
      property uri : DocumentUri
      property range : Range
      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range
      property data : JSON::Any?

      def initialize(@name : String, @kind : SymbolKind, @uri : DocumentUri, @range : Range, @selection_range : Range, @tags : Array(SymbolTag)? = nil, @detail : String? = nil, @data : JSON::Any? = nil)
      end
    end

    class CallHierarchyIncomingCall
      include JSON::Serializable

      property from : CallHierarchyItem
      @[JSON::Field(key: "fromRanges")]
      property from_ranges : Array(Range)

      def initialize(@from : CallHierarchyItem, @from_ranges : Array(Range))
      end
    end

    class CallHierarchyOutgoingCall
      include JSON::Serializable

      property to : CallHierarchyItem
      @[JSON::Field(key: "fromRanges")]
      property from_ranges : Array(Range)

      def initialize(@to : CallHierarchyItem, @from_ranges : Array(Range))
      end
    end

    class TypeHierarchyItem
      include JSON::Serializable

      property name : String
      property kind : SymbolKind
      property tags : Array(SymbolTag)?
      property detail : String?
      property uri : DocumentUri
      property range : Range
      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range
      property data : JSON::Any?

      def initialize(@name : String, @kind : SymbolKind, @uri : DocumentUri, @range : Range, @selection_range : Range, @tags : Array(SymbolTag)? = nil, @detail : String? = nil, @data : JSON::Any? = nil)
      end
    end

    class InlineValueText
      include JSON::Serializable

      property range : Range
      property text : String

      def initialize(@range : Range, @text : String)
      end
    end

    class InlineValueVariableLookup
      include JSON::Serializable

      property range : Range
      @[JSON::Field(key: "variableName")]
      property variable_name : String?
      @[JSON::Field(key: "caseSensitiveLookup")]
      property case_sensitive_lookup : Bool

      def initialize(@range : Range, @case_sensitive_lookup : Bool, @variable_name : String? = nil)
      end
    end

    class InlineValueEvaluatableExpression
      include JSON::Serializable

      property range : Range
      property expression : String?

      def initialize(@range : Range, @expression : String? = nil)
      end
    end

    alias InlineValue = InlineValueText | InlineValueVariableLookup | InlineValueEvaluatableExpression

    class InlineValueContext
      include JSON::Serializable

      @[JSON::Field(key: "frameId")]
      property frame_id : Int32
      @[JSON::Field(key: "stoppedLocation")]
      property stopped_location : Range

      def initialize(@frame_id : Int32, @stopped_location : Range)
      end
    end

    enum InlayHintKind : Int32
      Type = 1
      Parameter = 2
    end

    class InlayHintLabelPart
      include JSON::Serializable

      property value : String
      property tooltip : JSON::Any?
      property location : Location?
      property command : Command?

      def initialize(@value : String, @tooltip : JSON::Any? = nil, @location : Location? = nil, @command : Command? = nil)
      end
    end

    class InlayHint
      include JSON::Serializable

      property position : Position
      property label : JSON::Any
      property kind : InlayHintKind?
      @[JSON::Field(key: "textEdits")]
      property text_edits : TextEdits?
      property tooltip : JSON::Any?
      @[JSON::Field(key: "paddingLeft")]
      property padding_left : Bool?
      @[JSON::Field(key: "paddingRight")]
      property padding_right : Bool?
      property data : JSON::Any?

      def initialize(@position : Position, @label : JSON::Any, @kind : InlayHintKind? = nil, @text_edits : TextEdits? = nil, @tooltip : JSON::Any? = nil, @padding_left : Bool? = nil, @padding_right : Bool? = nil, @data : JSON::Any? = nil)
      end
    end

    class StringValue
      include JSON::Serializable

      property kind : String
      property value : String

      def initialize(@value : String)
        @kind = "snippet"
      end
    end

    class InlineCompletionItem
      include JSON::Serializable

      @[JSON::Field(key: "insertText")]
      property insert_text : String | StringValue
      @[JSON::Field(key: "filterText")]
      property filter_text : String?
      property range : Range?
      property command : Command?

      def initialize(@insert_text : String | StringValue, @filter_text : String? = nil, @range : Range? = nil, @command : Command? = nil)
      end
    end

    class InlineCompletionList
      include JSON::Serializable

      property items : Array(InlineCompletionItem)

      def initialize(@items : Array(InlineCompletionItem))
      end
    end

    enum InlineCompletionTriggerKind : Int32
      Invoked = 1
      Automatic = 2
    end

    class SelectedCompletionInfo
      include JSON::Serializable

      property range : Range
      property text : String

      def initialize(@range : Range, @text : String)
      end
    end

    class InlineCompletionContext
      include JSON::Serializable

      @[JSON::Field(key: "triggerKind")]
      property trigger_kind : InlineCompletionTriggerKind
      @[JSON::Field(key: "selectedCompletionInfo")]
      property selected_completion_info : SelectedCompletionInfo?

      def initialize(@trigger_kind : InlineCompletionTriggerKind, @selected_completion_info : SelectedCompletionInfo? = nil)
      end
    end

    # ---- Formatting ----

    class FormattingOptions
      include JSON::Serializable

      @[JSON::Field(key: "tabSize")]
      property tab_size : Int32
      @[JSON::Field(key: "insertSpaces")]
      property insert_spaces : Bool
      @[JSON::Field(key: "trimTrailingWhitespace")]
      property trim_trailing_whitespace : Bool?
      @[JSON::Field(key: "insertFinalNewline")]
      property insert_final_newline : Bool?
      @[JSON::Field(key: "trimFinalNewlines")]
      property trim_final_newlines : Bool?

      def initialize(
        @tab_size : Int32,
        @insert_spaces : Bool,
        @trim_trailing_whitespace : Bool? = nil,
        @insert_final_newline : Bool? = nil,
        @trim_final_newlines : Bool? = nil
      )
      end
    end

    class DocumentLink
      include JSON::Serializable

      property range : Range
      property target : String?
      property tooltip : String?
      property data : JSON::Any?

      def initialize(@range : Range, @target : String? = nil, @tooltip : String? = nil, @data : JSON::Any? = nil)
      end
    end

    # ---- File events ----

    enum FileChangeType : Int32
      Created = 1
      Changed = 2
      Deleted = 3
    end

    class FileEvent
      include JSON::Serializable

      property uri : DocumentUri
      property type : FileChangeType

      def initialize(@uri : DocumentUri, @type : FileChangeType)
      end
    end

    # ---- Request payloads ----

    class ClientInfo
      include JSON::Serializable

      property name : String
      property version : String?

      def initialize(@name : String, @version : String? = nil)
      end
    end

    # ServerInfo matches the LSP initialize result's optional serverInfo field.
    class ServerInfo
      include JSON::Serializable

      property name : String
      property version : String?

      def initialize(@name : String, @version : String? = nil)
      end
    end

    class InitializeRequest < Request
      @[JSON::Field(nested: "params", key: "capabilities")]
      property capabilities : ClientCapabilities?

      @[JSON::Field(nested: "params", key: "processId")]
      property process_id : Int32?

      @[JSON::Field(nested: "params", key: "rootPath")]
      property root_path : String?

      @[JSON::Field(nested: "params", key: "rootUri")]
      property root_uri : DocumentUri?

      # Optional user locale as defined by the client (e.g. "en-US").
      @[JSON::Field(nested: "params", key: "locale")]
      property locale : String?

      @[JSON::Field(nested: "params", key: "workspaceFolders")]
      property workspace_folders : Array(WorkspaceFolder)?

      @[JSON::Field(nested: "params", key: "clientInfo")]
      property client_info : ClientInfo?

      @[JSON::Field(nested: "params", key: "initializationOptions")]
      property initialization_options : JSON::Any?

      @[JSON::Field(nested: "params", key: "trace")]
      property trace : String?
    end

    class ShutdownRequest < Request
    end

    class CompletionRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position

      @[JSON::Field(nested: "params", key: "context")]
      property context : CompletionContext?
    end

    class HoverRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position
    end

    class SignatureHelpRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position
    end

    class DefinitionRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position
    end

    class ReferenceContext
      include JSON::Serializable

      @[JSON::Field(key: "includeDeclaration")]
      property include_declaration : Bool

      def initialize(@include_declaration : Bool)
      end
    end

    class ReferencesRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position

      @[JSON::Field(nested: "params", key: "context")]
      property context : ReferenceContext
    end

    class DocumentSymbolRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier
    end

    class WorkspaceSymbolRequest < Request
      @[JSON::Field(nested: "params", key: "query")]
      property query : String
    end

    class DocumentFormattingRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "options")]
      property options : FormattingOptions
    end

    class DocumentRangeFormattingRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "range")]
      property range : Range

      @[JSON::Field(nested: "params", key: "options")]
      property options : FormattingOptions
    end

    class RenameRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "position")]
      property position : Position

      @[JSON::Field(nested: "params", key: "newName")]
      property new_name : String
    end

    class ShowMessageRequest < Request
      @[JSON::Field(nested: "params")]
      property params_data : ShowMessageRequestParams

      def initialize(@id : IntegerOrString, @params_data : ShowMessageRequestParams)
        @method = "window/showMessageRequest"
      end
    end

    class DocumentDiagnosticRequest < Request
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "identifier")]
      property identifier : String?

      @[JSON::Field(nested: "params", key: "previousResultId")]
      property previous_result_id : String?

      @[JSON::Field(nested: "params", key: "workDoneToken")]
      property work_done_token : ProgressToken?

      @[JSON::Field(nested: "params", key: "partialResultToken")]
      property partial_result_token : ProgressToken?
    end

    class WorkspaceDiagnosticRequest < Request
      @[JSON::Field(nested: "params", key: "identifier")]
      property identifier : String?

      @[JSON::Field(nested: "params", key: "previousResultIds")]
      property previous_result_ids : Array(PreviousResultId)?

      @[JSON::Field(nested: "params", key: "workDoneToken")]
      property work_done_token : ProgressToken?

      @[JSON::Field(nested: "params", key: "partialResultToken")]
      property partial_result_token : ProgressToken?
    end

    # ---- Notifications ----

    class InitializedNotification < Notification
      def initialize
        @method = "initialized"
      end
    end

    class ExitNotification < Notification
      def initialize
        @method = "exit"
      end
    end

    class ShowMessageNotification < Notification
      @[JSON::Field(nested: "params")]
      property params_data : ShowMessageParams

      def initialize(@params_data : ShowMessageParams)
        @method = "window/showMessage"
      end
    end

    class LogMessageNotification < Notification
      @[JSON::Field(nested: "params")]
      property params_data : LogMessageParams

      def initialize(@params_data : LogMessageParams)
        @method = "window/logMessage"
      end
    end

    class DidOpenTextDocumentNotification < Notification
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentItem

      def initialize(@text_document : TextDocumentItem)
        @method = "textDocument/didOpen"
      end
    end

    class DidChangeTextDocumentNotification < Notification
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : VersionedTextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "contentChanges")]
      property content_changes : Array(TextDocumentContentChangeEvent)

      def initialize(@text_document : VersionedTextDocumentIdentifier, @content_changes : Array(TextDocumentContentChangeEvent))
        @method = "textDocument/didChange"
      end
    end

    class DidCloseTextDocumentNotification < Notification
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      def initialize(@text_document : TextDocumentIdentifier)
        @method = "textDocument/didClose"
      end
    end

    class DidSaveTextDocumentNotification < Notification
      @[JSON::Field(nested: "params", key: "textDocument")]
      property text_document : TextDocumentIdentifier

      @[JSON::Field(nested: "params", key: "text")]
      property text : String?

      def initialize(@text_document : TextDocumentIdentifier, @text : String? = nil)
        @method = "textDocument/didSave"
      end
    end

    class DidChangeConfigurationParams
      include JSON::Serializable

      property settings : JSON::Any
    end

    class DidChangeConfigurationNotification < Notification
      @[JSON::Field(nested: "params")]
      property params_data : DidChangeConfigurationParams? = nil

      def initialize(@params_data : DidChangeConfigurationParams? = nil)
        @method = "workspace/didChangeConfiguration"
      end
    end

    class DidChangeWatchedFilesParams
      include JSON::Serializable

      property changes : Array(FileEvent)
    end

    class DidChangeWatchedFilesNotification < Notification
      @[JSON::Field(nested: "params")]
      property params_data : DidChangeWatchedFilesParams? = nil

      def initialize(@params_data : DidChangeWatchedFilesParams? = nil)
        @method = "workspace/didChangeWatchedFiles"
      end
    end
  end
end
