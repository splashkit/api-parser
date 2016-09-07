require_relative 'abstract_translator'

module Translators
  #
  # C++ Front-End Translator
  #
  class CPP < AbstractTranslator
    def initialize(data, src)
      super(data, src)
      # C++ is a superset of C, so we can reuse our CLib implementations
      @clib = CLib.new(@data, @src)
    end

    def render_templates
      result = @data.map do |header_key, header_data|
        header_file_name = "#{header_key}.h"
        header_contents  = Header.new(header_data, @src)
                                 .read_template('header/module_header.h')
        [header_file_name, header_contents]
      end.to_h
      result.merge(
        'sklib.h'   => read_template('header/sklib_header.h'),
        'sklib.cpp' => read_template('implementation/implementation.cpp')
      )
    end

    #=== internal ===

    private

    class Header < CPP; end
    class Implementation < CPP; end

    #
    # Generate a C++ type signature from a SK function
    #
    def cpp_signature_for(function)
      name            = function[:name]
      return_type     = cpp_type_for function[:return]
      parameter_list  = cpp_parameter_list_for function
      "#{return_type} #{name}(#{parameter_list})"
    end

    #
    # Convert a list of parameters to a C++ parameter list
    #
    def cpp_parameter_list_for(function)
      function[:parameters].reduce('') do |memo, param|
        param_name = param.first
        param_data = param.last
        type = cpp_type_for param_data
        ptr = param_data[:is_pointer]   ? '*' : ''
        ref = param_data[:is_reference] ? '&' : ''
        const = param_data[:is_const] ? 'const ' : ''
        "#{memo}, #{const}#{type} #{ptr}#{ref}#{param_name}"
      end[2..-1]
    end

    #
    # Generates a field's struct information
    #
    def cpp_struct_field_for(field_name, field_data)
      type = cpp_type_for field_data
      ptr = field_data[:is_pointer] ? '*' : ''
      ref = field_data[:is_reference] ? '&' : ''
      if field_data[:is_array]
        array_dims = field_data[:array_dimension_sizes]
        array_decl =
          if array_dims.length == 1
            "[#{array_dims.first}]"
          else
            "[#{array_dims.first}][#{array_dims.last}]"
          end
      end
      "#{type} #{ptr}#{ref}#{field_name}#{array_decl}"
    end

    #
    # Converts SK type to C++ type
    #
    def cpp_type_for(type_data)
      # Only hardcode mapping we need
      return 'unsigned char' if type_data[:type] == 'byte'
      type_data[:type]
    end

    #
    # C Lib type to C++ type adapter
    #
    def cpp_adapter_fn_for(function)
      # Just use clib SK adapter -- it's the same thing
      @clib.sk_adapter_fn_for(function)
    end
  end
end