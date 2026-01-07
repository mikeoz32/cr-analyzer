require "compiler/crystal/syntax"

class Crystal::Path
  def full : String
    names.join("::")
  end
end
