require "../src/cra/workspace"

private def canonical_type(ref : CRA::Psi::TypeRef?) : String
  return "" unless ref
  if ref.union?
    return ref.union_types.map { |member| canonical_type(member) }.join(" | ")
  end

  name = ref.name.to_s
  name = name.byte_slice(2, name.bytesize - 2) if name.starts_with?("::")
  return name if ref.args.empty?
  "#{name}(#{ref.args.map { |arg| canonical_type(arg) }.join(", ")})"
end

private def declaration_contract(index : CRA::Psi::SemanticIndex, uri : String) : Array(String)
  values = [] of String
  index.type_names_for_file(uri).each do |name|
    owner = index.find_class(name) || index.find_module(name) || index.find_enum(name)
    next unless owner

    methods = case owner
              when CRA::Psi::Class  then owner.methods
              when CRA::Psi::Module then owner.methods
              when CRA::Psi::Enum   then owner.methods
              else                       [] of CRA::Psi::Method
              end
    methods.each do |method|
      next unless method.file == uri
      values << [
        owner.name,
        method.name,
        method.min_arity,
        method.max_arity,
        method.class_method,
        method.parameters.join(","),
        canonical_type(method.return_type_ref),
      ].join("|")
    end

    if owner.is_a?(CRA::Psi::Enum)
      owner.members.each do |member|
        values << "#{owner.name}|enum-member|#{member.name}" if member.file == uri
      end
    end
  end
  values.sort
end

root = Path.new(ARGV[0]? || Dir.current).expand
ENV["CRA_SKIP_STDLIB_SCAN"] = "1"
workspace = CRA::Workspace.from_s("file://#{root}")
workspace.scan

files = Dir.glob(root.join("{src,spec}/**/*.cr").to_s).sort
comparable = 0
exact = 0
recoveries = 0
mismatches = 0

files.each do |path|
  uri = "file://#{path}"
  crystal_types = workspace.analyzer.type_names_for_file(uri).sort
  facet_types = workspace.facet_analyzer.type_names_for_file(uri).sort

  if crystal_types.empty? && !facet_types.empty?
    recoveries += 1
    puts "FACET_RECOVERY #{path}: #{facet_types.join(", ")}"
    next
  end

  comparable += 1
  crystal_contract = declaration_contract(workspace.analyzer, uri)
  facet_contract = declaration_contract(workspace.facet_analyzer, uri)
  if crystal_types == facet_types && crystal_contract == facet_contract
    exact += 1
    next
  end

  mismatches += 1
  puts "MISMATCH #{path}"
  puts "  missing types: #{(crystal_types - facet_types).join(", ")}" unless crystal_types == facet_types
  puts "  extra types: #{(facet_types - crystal_types).join(", ")}" unless crystal_types == facet_types
  puts "  missing declarations: #{(crystal_contract - facet_contract).first(10).join(", ")}" unless crystal_contract == facet_contract
  puts "  extra declarations: #{(facet_contract - crystal_contract).first(10).join(", ")}" unless crystal_contract == facet_contract
end

puts "files=#{files.size} comparable=#{comparable} exact=#{exact} facet_recoveries=#{recoveries} mismatches=#{mismatches}"
exit(1) unless mismatches == 0
