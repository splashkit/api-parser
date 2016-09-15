require_relative 'logger'

#
# Parses HeaderDoc into Ruby
#
class Parser
  # Monkey patch Nokogiri to squash data down
  require 'nokogiri'
  require_relative '../lib/core_ext/nokogiri/xml'

  # Improved IO
  require 'open3'

  # Logging support
  include Logger

  # Case conversion helpers
  require_relative '../lib/core_ext/string'

  #
  # Checks if HeaderDoc is installed
  #
  def headerdoc_installed?
    system %(which headerdoc2html > /dev/null)
  end

  #
  # Initialiser with src
  #
  def initialize(src)
    @src = src
  end

  #
  # Parses HeaderDoc for the provided src directory into a hash
  #
  def parse
    unless headerdoc_installed?
      raise Parser::Error 'headerdoc2html is not installed!'
    end
    hcfg_file = File.expand_path('../../res/headerdoc.config', __FILE__)
    # If only parsing one file then don't amend /*.h
    headers_src = "#{@src}/#{SK_SRC_CORESDK}/*.h" unless @src.end_with? '.h'
    parsed = Dir[headers_src || @src].map do |hfile|
      puts "Parsing #{hfile}..."
      cmd = %(headerdoc2html -XPOLltjbq -c #{hcfg_file} #{hfile})
      _, stdout, stderr, wait_thr = Open3.popen3 cmd
      out = stdout.readlines
      errs = stderr.readlines.join.gsub(/-{3,}(?:.|\n)+?-(?=\n)\n/, '').split("\n")
      errs.each { |e| warn e }
      exit_status = wait_thr.value.exitstatus
      hfile_xml = out.empty? ? nil : out.join
      unless exit_status.zero?
        raise Parser::Error,
              "headerdoc2html failed. Command was #{cmd}."
      end
      xml = Nokogiri.XML(hfile_xml)
      hfparser = HeaderFileParser.new(File.basename(hfile), xml)
      [hfparser.name.to_sym, hfparser.parse]
    end
    if parsed.empty?
      raise Parser::Error, %{
Nothing parsed! Check that #{@src} is the correct SplashKit directory and that
coresdk/src/coresdk contains the correct C++ source. Check that HeaderDoc
comments exist (refer to README).
}
    end
    parsed.to_h
  end
end

#
# Class for raising parsing errors
#
class Parser::Error < StandardError
  attr_accessor :signature

  def initialize(message, signature = nil)
    @message = message =~ /(?:\?|\.)$/ ? message : message << '.'
    return super(message) unless signature
    @signature = signature
  end

  def to_s
    if @signature
      "HeaderDoc parser violation on `#{@signature}`:\n\t#{@message}"
    else
      @message
    end
  end
end

#
# Class for raising parsing rule errors
#
class Parser::RuleViolationError < Parser::Error
  def initialize(message, rule_no)
    super message << "\n\tSee "\
          "https://github.com/splashkit/splashkit-translator\#rule-#{rule_no} "\
          'for more information.'
  end
end

#
# Class to parse a single header file
#
class Parser::HeaderFileParser
  attr_reader :name

  # Logging support
  include Logger

  #
  # Initialises a header parser with required data
  #
  def initialize(name, input_xml)
    @name = name[0..-3] # remove the '.h'
    @header_attrs = {}
    @input_xml = input_xml
    @unique_names = { unique_global: [], unique_method: [] }
  end

  #
  # Parses the header file
  #
  def parse
    # Start directly from 'header' node
    parse_xml(@input_xml.xpath('header'))
  end

  private

  #
  # A function which will default to the ppl provided if they are missing
  # within the hash provided using the parse_func provided
  #
  def ppl_default_to(xml, hash, ppl, parse_func = :parse_parameter_info)
    ppl.each do |p_name, p_type|
      args = [xml, p_name, p_type]
      result = parse_func ? send(parse_func, *args) : {}
      hash[p_name] = (hash[p_name] || {}).merge(result)
    end
    hash
  end

  #
  # Parses HeaderDoc's parsedparameterlist (ppl) element
  #
  def parse_ppl(xml)
    xml.xpath('parsedparameterlist/parsedparameter').map do |p|
      [p.xpath('name').text.to_sym, p.xpath('type').text]
    end.to_h
  end

  #
  # Parses a signature from HeaderDoc's declaration element
  #
  def parse_signature(xml)
    xml.xpath('declaration').text.split(/\n/).map(&:strip).join()
  end

  #
  # Parses the docblock at the start of a .h file
  #
  def parse_header(xml)
    @header_attrs = parse_attributes(xml).reject { |k, _| k == :Author }
    {
      name:         @name.to_s,
      brief:        xml.xpath('abstract').text,
      description:  xml.xpath('desc').text
    }
  end

  #
  # Parses a single `@attribute` in a docblock
  #
  def parse_attribute(xml)
    [xml.xpath('name').text.to_sym, xml.xpath('value').text]
  end

  #
  # Parses all attributes in a docblock
  #
  def parse_attributes(xml, ppl = nil)
    attrs = xml.xpath('attributes/attribute')
               .map { |a| parse_attribute(a) }
               .to_h
               .merge @header_attrs
    # Method, self, destructor, constructor must have a class attribute also
    enforce_class_keys = [
      :self,
      :destructor,
      :constructor
    ]
    enforced_class_keys_found = attrs.keys & enforce_class_keys
    has_enforced_class_keys = !enforced_class_keys_found.empty?
    if has_enforced_class_keys && attrs[:class].nil?
      raise Parser::RuleViolationError.new(
            "Attribute(s) `#{enforced_class_keys_found.map(&:to_s)
            .join('\', `')}' found, but `class' attribute is missing?", 1)
    end
    # `method`, `getter` or `setter` must have `class` or `static`
    method_getter_static_keys_found = attrs.keys & [:method, :getter, :setter]
    class_static_keys_found = attrs.keys & [:class, :static]
    if !method_getter_static_keys_found.empty? &&
       class_static_keys_found.empty?
      raise Parser::RuleViolationError.new(
            'Attributes `getter` and `setter` must also specify either ' \
            '`class` or `static` attributes (or both).', 2)
    end
    # Can't have `destructor` & `constructor`
    if attrs[:destructor] && attrs[:constructor]
      raise Parser::RuleViolationError.new(
            'Attributes `destructor` and `constructor` conflict.', 3)
    end
    # Can't have (`destructor` | `constructor`) & (`setter` | `getter`) if
    # not marked with `static`
    marked_with_static = !attrs[:static].nil?
    destructor_constructor_keys_found = attrs.keys & [:constructor, :destructor]
    getter_setter_keys_found = attrs.keys & [:getter, :setter]
    if !destructor_constructor_keys_found.empty? &&
       !getter_setter_keys_found.empty? &&
       !marked_with_static
      raise Parser::RuleViolationError.new(
            "Attribute(s) `#{destructor_constructor_keys_found.map(&:to_s)
            .join('\', `')}' violate `#{getter_setter_keys_found.map(&:to_s)
            .join('\', `')}'. Choose one or the other.", 4)
    end
    # Can't have (`destructor` | `constructor`) & `method` if no `static`
    if !destructor_constructor_keys_found.empty? &&
       !attrs[:method].nil? &&
       !marked_with_static
      raise Parser::RuleViolationError.new(
            "Attribute(s) `#{destructor_constructor_keys_found.map(&:to_s)
            .join('\', `')}' violate `method`. Choose one or the other " \
            'or mark with `static` to indicate that this is a static ' \
            'method.', 5)
    end
    # Can't have (`setter` | `getter`) & `method` if no `static`
    if !getter_setter_keys_found.empty? &&
       attrs[:method] &&
       !marked_with_static
      raise Parser::RuleViolationError.new(
            "Attribute(s) `#{getter_setter_keys_found.map(&:to_s)
            .join('\', `')}' violate `method`. Choose one or the other " \
            'or mark with `static` to indicate that this is a static ' \
            'method.', 6)
    end
    # Ensure `self` matches a parameter
    self_value = attrs[:self]
    if self_value && ppl && ppl[self_value.to_sym].nil?
      raise Parser::RuleViolationError.new(
            'Attribute `self` must be set to the name of a parameter.', 7)
    end
    # Ensure the parameter set by `self` attribute has the same type indicated
    # by the `class`
    if self_value && ppl
      class_type = attrs[:class]
      self_type  = ppl[self_value.to_sym]
      unless class_type == self_type
        raise Parser::RuleViolationError.new(
              'Attribute `self` must list a parameter whose type matches ' \
              "the `class` value (`class` is `#{class_type}` but `self` " \
              "is set to parameter (`#{self_value}`) with type " \
              "`#{self_type}`).", 8)
      end
    end
    # `getter` must be non-void
    ret_type = parse_function_return_type(xml)
    is_void = ret_type && ret_type[:type] == 'void' && !ret_type[:is_pointer]
    if attrs[:getter] && is_void
      raise Parser::RuleViolationError.new(
            'Function marked with `getter` must return something (i.e., '\
            'it should not return `void`).', 9)
    end
    # `class` rules applicable to `getter`s and `setter`s
    if attrs[:class]
      # Getters must have 1 parameter which is self
      if attrs[:getters] && ppl && ppl.length != 1 && attrs[:self]
        raise Parser::RuleViolationError.new(
              'A `getter` specified with `class` must have exactly one '\
              'parameter that is the parameter specified by the '\
              'attribute `self`.', 10)
      end
      # Setters must have 2 parameters
      if attrs[:setters] && ppl && ppl.length != 2 && attrs[:self] == ppl.keys.first
        raise Parser::RuleViolationError.new(
              'A `setter` specified with `class` must have exactly two '\
              'parameters of which the first parameter is the parameter '\
              'specified by the attribute `self`.', 11)
      end
    end
    # `static` rules applicable to `getter`s and `setter`s
    if attrs[:class]
      # Getters must have 0 parameters
      if attrs[:getters] && ppl && ppl.empty?
        raise Parser::RuleViolationError.new(
              'A `getter` specified with `static` must have no parameters',
              12)
      end
      # Setters must have 2 parameters
      if attrs[:setters] && ppl && ppl.length != 2
        raise Parser::RuleViolationError.new(
              'A `setter` specified with `static` must have one parameter', 13)
      end
    end
    attrs
  end

  #
  # Parses array sizes from a given xml using its `<declaration>` and the
  # given type name desired. If no array sizes are found, nil is returned.
  # Otherwise each dimension and its size is given in order as an array.
  # E.g., float three_by_two_matrix[3][2] => [3,3]
  #
  def parse_array_dimensions(xml, search_for_name)
    xpath_query = 'declaration/*[preceding-sibling::declaration_type[' \
                  "text() = '#{search_for_name}']]"
    dims = xml.xpath(xpath_query).map(&:text).take_while(&:int?).map(&:to_i)
    if dims.length > 2
      raise Parser::Error,
            'Only 1 and 2 dimensional arrays are supported at this time ' \
            "(got a #{dims.length}D array for `#{search_for_name}')."
    end
    dims
  end

  #
  # Returns parameter type information based on the type and desc given
  #
  def parse_parameter_info(xml, param_name, ppl_type_data)
    regex = /(?:(const)\s+)?((?:unsigned\s)?\w+)\s*(?:(&amp;)|(\*)|(\[\d+\])*)?/
    _, const, type, ref, ptr = *(ppl_type_data.match regex)

    # Grab template <T> value for parameter
    type_parameter, is_vector = *parse_vector(xml, type)
    is_vector = type == 'vector'

    array = parse_array_dimensions(xml, param_name)
    {
      type: type,
      description: xml.xpath('desc').text,
      is_pointer: !ptr.nil?,
      is_const: !const.nil?,
      is_reference: !ref.nil?,
      is_array: !array.empty?,
      array_dimension_sizes: array,
      is_vector: is_vector,
      type_parameter: type_parameter
    }
  end

  #
  # Parses a single `@param` in a docblock
  #
  def parse_parameter(xml, ppl)
    name = xml.xpath('name').text
    # Need to find the matching type, this comes from
    # the parsed parameter list elements
    type = ppl[name.to_sym]
    if type.nil?
      raise Parser::Error,
            "Mismatched headerdoc @param '#{name}'. Check it exists in the " \
            'signature.'
    end
    [
      name.to_sym,
      parse_parameter_info(xml, name, type)
    ]
  end

  #
  # Parses all parameters in a docblock
  #
  def parse_parameters(xml, ppl)
    params = xml.xpath('parameters/parameter').map do |p|
      parse_parameter(p, ppl)
    end.to_h
    ppl_default_to(xml, params, ppl)
  end

  #
  # Returns vector information if a vector is parsed
  #
  def parse_vector(xml, type)
    # Extract template <T> value for parameter
    is_vector = type == 'vector'
    if is_vector
      type_parameter = xml.xpath('declaration/declaration_template').text
    end
    # Vector of vectors...
    if is_vector && type_parameter == 'vector'
      raise Parser::Error('Vectors of vectors not yet supported!')
    end
    [
      type_parameter,
      is_vector
    ]
  end

  #
  # Parses a function (pointer) return type
  #
  def parse_function_return_type(xml, raw_return_type = nil)
    returntype_xml = xml.xpath('returntype')
    # Return if no results
    return if returntype_xml.empty? && raw_return_type.nil?
    raw_return_type ||= returntype_xml.text
    ret_type_regex = /((?:unsigned\s)?\w+)\s*(?:(&)|(\*)?)/
    _, type, ref, ptr = *(raw_return_type.match ret_type_regex)
    is_pointer = !ptr.nil?
    is_reference = !ref.nil?
    # Extract <T> from generic returns
    type_parameter, is_vector = *parse_vector(xml, type)
    desc = xml.xpath('result').text
    # Check that pure functions don't have return description
    if raw_return_type.nil? && type == 'void' && desc && (is_pointer || is_reference)
      raise Parser::Error,
            'Pure procedures should not have an `@returns` labelled.'
    end
    {
      type: type,
      description: desc,
      is_pointer: is_pointer,
      is_reference: is_reference,
      is_vector: is_vector,
      type_parameter: type_parameter,
    }
  end

  #
  # Parses a function's name for both a unique and standard name
  #
  def parse_function_names(xml, attributes)
    # Originally, headerdoc does overloaded names like name(int, const float).
    headerdoc_overload_tags = /const|\(|\,\s|\)|&|\*/
    fn_name = xml.xpath('name').text
    headerdoc_idx = fn_name.index(headerdoc_overload_tags)
    sanitized_name = headerdoc_idx ? fn_name[0..(headerdoc_idx - 1)] : fn_name
    suffix = attributes[:suffix] if attributes
    # Make a method name if specified
    method_name = attributes[:method] if attributes
    # Make a unique name using the suffix if specified
    if suffix
      unique_global_name = "#{sanitized_name}_#{suffix}"
      unique_method_name = "#{method_name}_#{suffix}" unless method_name.nil?
    end
    # Unique global name was made?
    unless unique_global_name.nil?
      # Check if unique name is actually unique
      if @unique_names[:unique_global].include? unique_global_name
        raise Parser::RuleViolationError.new(
              'Generated unique name (function name + suffix) is not unique: ' \
              "`#{sanitized_name}` + `#{suffix}` = `#{unique_global_name}`", 14)
      else
        @unique_names[:unique_global] << unique_global_name
      end
    end
    # Unique method name was made?
    unless unique_method_name.nil?
      # Check if unique method name is actually unique
      if @unique_names[:unique_method].include? unique_method_name
        raise Parser::RuleViolationError.new(
              'Generated unique method name (method + suffix) is not unique: ' \
              "`#{method}` + `#{suffix}` = `#{unique_method_name}`", 15)
      # Else register the unique name
      else
        @unique_names[:unique_method] << unique_method_name
      end
    end
    {
      sanitized_name: sanitized_name,
      method_name: method_name,
      unique_global_name: unique_global_name,
      unique_method_name: unique_method_name
    }
  end

  #
  # Parses the docblock of a function
  #
  def parse_function(xml)
    signature = parse_signature(xml)
    # Values from the <parsedparameter> elements
    ppl = parse_ppl(xml)
    attributes = parse_attributes(xml, ppl)
    parameters = parse_parameters(xml, ppl)
    fn_names = parse_function_names(xml, attributes)
    return_data = parse_function_return_type(xml)
    {
      signature:          signature,
      name:               fn_names[:sanitized_name],
      method_name:        fn_names[:method_name],
      unique_global_name: fn_names[:unique_global_name],
      unique_method_name: fn_names[:unique_method_name],
      suffix_name:        fn_names[:suffix],
      description:        xml.xpath('desc').text,
      brief:              xml.xpath('abstract').text,
      return:             return_data,
      parameters:         parameters,
      attributes:         attributes
    }
  rescue Parser::Error => e
    e.signature = signature
    error e
  end

  #
  # Parses all functions in the xml provided
  #
  def parse_functions(xml)
    xml.xpath('functions/function').map { |fn| parse_function(fn) }
  end

  #
  # Parses a function-pointer typedef
  #
  def parse_function_pointer_typedef(xml)
    ppl = parse_ppl(xml)
    return_type = xml.xpath('declaration/declaration_type[1]').text
    params = ppl_default_to(xml, {}, ppl) # just use PPL for this
    {
      return: parse_function_return_type(xml, return_type),
      parameters: params
    }
  end

  #
  # Checks if a typedef is a function pointer typedef (else it's 'simple')
  #
  def typedef_is_a_fn_ptr?(xml)
    xml.xpath('@type').text == 'funcPtr'
  end

  #
  # Parses a typedef signature for extended information that HeaderDoc does
  # not parse in
  #
  def parse_simple_typedef(signature)
    regex = /typedef\s+(\w+)?\s+(\w+)\s+(\*)?(\w+);$/
    _,
    aliased_type,
    aliased_identifier,
    is_pointer,
    new_identifier = *(regex.match signature)
    {
      aliased_type: aliased_type,
      aliased_identifier: aliased_identifier,
      is_pointer: !is_pointer.nil?,
      new_identifier: new_identifier
    }
  end

  #
  # Parses a single typedef
  #
  def parse_typedef(xml)
    is_fn_ptr = typedef_is_a_fn_ptr?(xml)
    signature = parse_signature(xml)
    attributes = parse_attributes(xml)
    merge_data = is_fn_ptr ? parse_function_pointer_typedef(xml) : parse_simple_typedef(xml)
    data = {
      signature:           signature,
      name:                xml.xpath('name').text,
      description:         xml.xpath('desc').text,
      brief:               xml.xpath('abstract').text,
      attributes:          attributes,
      is_function_pointer: is_fn_ptr
    }.merge merge_data
    if attributes && attributes[:class].nil? && data[:is_pointer]
      raise Parser::RuleViolationError.new(
            'Typealiases to pointers must have a class attribute set', 16)
    end
    data
  rescue Parser::Error => e
    e.signature = signature
    error e
  end

  #
  # Parses all typedefs in the xml provided
  #
  def parse_typedefs(xml)
    xml.xpath('typedefs/typedef').map { |td| parse_typedef(td) }
  end

  #
  # Parses all fields (marked with `@param`) in a struct
  #
  def parse_fields(xml, ppl)
    fields = xml.xpath('fields/field').map do |p|
      # fields are marked with `@param`, so we just use parse_parameter
      parse_parameter(p, ppl)
    end.to_h
    ppl_default_to(xml, fields, ppl)
  end

  #
  # Parses a single struct
  #
  def parse_struct(xml)
    signature = parse_signature(xml)
    ppl = parse_ppl(xml)
    {
      signature:   signature,
      name:        xml.xpath('name').text,
      description: xml.xpath('desc').text,
      brief:       xml.xpath('abstract').text,
      fields:      parse_fields(xml, ppl),
      attributes:  parse_attributes(xml)
    }
  rescue Parser::Error => e
    e.signature = signature
    error e
  end

  #
  # Parses all structs in the xml provided
  #
  def parse_structs(xml)
    xml.xpath('structs_and_unions/struct').map { |s| parse_struct(s) }
  end

  #
  # Parses enum numbers on a constant
  #
  def parse_enum_constant_numbers(xml, constants)
    xpath_query = "declaration/*[name() = 'declaration_var' or " \
                  "              name() = 'declaration_number']"
    result = xml.xpath(xpath_query)
    result.each_with_index do |parsed, i|
      # Is this a declaration_var?
      if parsed.name == 'declaration_var'
        # Does it exist in the list of constants?
        constant_name = parsed.text.to_sym
        if constants[constant_name]
          # Is the next a declaration_number?
          next_el = result[i+1]
          next unless next_el
          if next_el.name == 'declaration_number'
            # This number matches the constant
            constants[constant_name][:number] = next_el.text.to_i
          end
        end
      end
    end
    constants
  end

  #
  # Parse a single enum constant data
  #
  def parse_enum_constant(xml)
    { description: xml.xpath('desc').text }
  end

  #
  # Parses enum constants
  #
  def parse_enum_constants(xml, ppl)
    constants = xml.xpath('constants/constant').map do |const|
      [xml.xpath('name').text.to_sym, parse_enum_constant(const)]
    end.to_h
    # after parsing <constant>, must ensure they align with the ppl
    constants.keys.each do | const |
      # ppl for enums have no types! Thus, just check against keys
      unless ppl.keys.include? const
        raise Parser::Error,
              "Mismatched headerdoc @constant '#{const}'. Check it exists " \
              'in the enum definition.'
      end
    end
    ppl_default_to(xml, constants, ppl, nil)
    parse_enum_constant_numbers(xml, constants)
  end

  #
  # Parses a single enum
  #
  def parse_enum(xml)
    signature = parse_signature(xml)
    ppl = parse_ppl(xml)
    {
      signature:   signature,
      name:        xml.xpath('name').text,
      description: xml.xpath('desc').text,
      brief:       xml.xpath('abstract').text,
      constants:   parse_enum_constants(xml, ppl),
      attributes:  parse_attributes(xml)
    }
  rescue Parser::Error => e
    e.signature = signature
    error e
  end

  #
  # Parses all enums in the xml provided
  #
  def parse_enums(xml)
    xml.xpath('enums/enum').map { |e| parse_enum(e) }
  end

  #
  # Parses a single define
  #
  def parse_define(xml)
    definition_xpath = 'declaration/declaration_preprocessor[position() > 2]'
    {
      name:        xml.xpath('name').text,
      description: xml.xpath('desc').text,
      brief:       xml.xpath('abstract').text,
      definition:  xml.xpath(definition_xpath).text
    }
  end

  #
  # Parses all hash defines in the xml provided
  #
  def parse_defines(xml)
    xml.xpath('defines/pdefine').map { |d| parse_define(d) }
  end

  #
  # Parses the XML into a hash representing the object model of every header
  # file
  #
  def parse_xml(xml)
    parsed = parse_header(xml)
    parsed[:functions]   = parse_functions(xml)
    parsed[:typedefs]    = parse_typedefs(xml)
    parsed[:structs]     = parse_structs(xml)
    parsed[:enums]       = parse_enums(xml)
    parsed[:defines]     = parse_defines(xml)
    parsed
  end
end
