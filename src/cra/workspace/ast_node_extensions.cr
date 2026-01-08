require "../types"
require "compiler/crystal/syntax"

class Crystal::ASTNode
  def range : CRA::Types::Range
    location.try do |loc|
      return CRA::Types::Range.new(
        start_position: CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
        end_position:   CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1)
      )
    end
    CRA::Types::Range.new(
      start_position: CRA::Types::Position.new(line: 0, character: 0),
      end_position:   CRA::Types::Position.new(line: 0, character: 0)
    )
  end

  def symbol_kind : CRA::Types::SymbolKind
    case self
    when Crystal::ModuleDef
      CRA::Types::SymbolKind::Module
    when Crystal::ClassDef
      CRA::Types::SymbolKind::Class
    when Crystal::EnumDef
      CRA::Types::SymbolKind::Enum
    when Crystal::Def
      CRA::Types::SymbolKind::Method
    when Crystal::InstanceVar
      CRA::Types::SymbolKind::Property
    else
      CRA::Types::SymbolKind::String
    end
  end

  def to_symbol_info(uri : String?, container_name : String?) : CRA::Types::SymbolInformation
    CRA::Types::SymbolInformation.new(
      name: name.to_s,
      kind: symbol_kind,
      container_name: container_name,
      location: CRA::Types::Location.new(
        uri: uri || "",
        range: range
      )
    )
  end
end
