# frozen_string_literal: true

require 'stringio'
require 'ostruct'

module PHP
	class StringIOReader < StringIO
		# Reads data from the buffer until +char+ is found. The
		# returned string will include +char+.
		def read_until(char)
			val, cpos = '', pos
			if idx = string.index(char, cpos)
				val = read(idx - cpos + 1)
			end
			val
		end
	end

	# Represents a serialized PHP object
	class PhpObject < OpenStruct
		# @return [String] The name of the original PHP class
		attr_accessor :_php_classname

		def to_assoc
			each_pair.to_a
		end
	end

	module SerializationState
		class Base
			def initialize
				@last_processed_value_index = -1
			end

			# @return [Boolean]
			attr_accessor :assoc

			# @return [Integer]
			attr_accessor :last_processed_value_index
		end

		class ToSerialize < Base
			def initialize
				super
				@serialized_object_id_to_index_map = {}
			end

			# @return [Hash{Integer => Integer}]
			attr_accessor :serialized_object_id_to_index_map
		end

		class ToUnserialize < Base
			def initialize
				super
				@classmap = {}
				@unserialized_values = []
			end

			# @return [Hash{String => Class}]
			attr_accessor :classmap

			# @return [String]
			attr_accessor :original_encoding

			# @return [Array<Object>]
			attr_accessor :unserialized_values
		end
	end

	# Returns a string representing the argument in a form PHP.unserialize
	# and PHP's unserialize() should both be able to load.
	#
	#   string = PHP.serialize(mixed var[, bool assoc])
	#
	# Array, Hash, Fixnum, Float, True/FalseClass, NilClass, String and Struct
	# are supported; as are objects which support the to_assoc method, which
	# returns an array of the form [['attr_name', 'value']..].  Anything else
	# will raise a TypeError.
	#
	# If 'assoc' is specified, Array's who's first element is a two value
	# array will be assumed to be an associative array, and will be serialized
	# as a PHP associative array rather than a multidimensional array.
	def PHP.serialize(var, assoc = false) # {{{
		state = SerializationState::ToSerialize.new.tap { |state|
			state.assoc = assoc
		}
		do_serialize(var, state)
	end

	def PHP.do_serialize(var, state)
		this_value_index = (state.last_processed_value_index += 1)
		s = String.new
		case var
			when Array
				s << "a:#{var.size}:{"
				if state.assoc and var.first.is_a?(Array) and var.first.size == 2
					var.each { |k,v|
						s << PHP.do_serialize(k, state) << PHP.do_serialize(v, state)
					}
				else
					var.each_with_index { |v,i|
						s << PHP.do_serialize(i, state) << PHP.do_serialize(v, state)
					}
				end

				s << '}'

			when Hash
				s << "a:#{var.size}:{"
				var.each do |k,v|
					s << "#{PHP.do_serialize(k, state)}#{PHP.do_serialize(v, state)}"
				end
				s << '}'

			when Struct
				s =
					handling_reference_for_recurring_object(var, index: this_value_index, state: state) {
						# encode as Object with same name
						s << "O:#{var.class.to_s.bytesize}:\"#{var.class.to_s.downcase}\":#{var.members.length}:{"
						var.members.each do |member|
							s << "#{PHP.do_serialize(member, state)}#{PHP.do_serialize(var[member], state)}"
						end
						s << '}'
					}

			when String, Symbol
				s << "s:#{var.to_s.bytesize}:\"#{var.to_s}\";"

			when Integer
				s << "i:#{var};"

			when Float
				s << "d:#{var};"

			when NilClass
				s << 'N;'

			when FalseClass, TrueClass
				s << "b:#{var ? 1 : 0};"

			else
				if var.respond_to?(:to_assoc)
					s =
						handling_reference_for_recurring_object(var, index: this_value_index, state: state) {
							v = var.to_assoc
							# encode as Object with same name
					class_name = var.respond_to?(:_php_classname) ? var._php_classname : var.class.to_s.downcase
					s << "O:#{class_name.bytesize}:\"#{class_name}\":#{v.length}:{"
							v.each do |k,v|
								s << "#{PHP.do_serialize(k.to_s, state)}#{PHP.do_serialize(v, state)}"
							end
							s << '}'
						}
				else
					raise TypeError, "Unable to serialize type #{var.class}"
				end
		end

		s
	end # }}}

	module InternalMethodsForSerialize
		private
		# Generate an object reference ('r') for a recurring object instead of serializing it again.
		#
		# @param [Object] object object to be serialized
		# @param [Integer] index index of serialized value
		# @param [SerializationState::ToSerialize] state
		# @param [Proc] block original procedure to serialize value
		# @return [String] serialized value or reference
		def handling_reference_for_recurring_object(object, index:, state:, &block)
			index_of_object_serialized_before = state.serialized_object_id_to_index_map[object.__id__]
			if index_of_object_serialized_before
				"r:#{index_of_object_serialized_before};"
			else
				state.serialized_object_id_to_index_map[object.__id__] = index
				yield
			end
		end
	end
	extend InternalMethodsForSerialize

	# Like PHP.serialize, but only accepts a Hash or associative Array as the root
	# type.  The results are returned in PHP session format.
	#
	#   string = PHP.serialize_session(mixed var[, bool assoc])
	def PHP.serialize_session(var, assoc = false) # {{{
		s = String.new
		case var
		when Hash
			var.each do |key,value|
				if key.to_s.include?('|')
					raise IndexError, "Top level names may not contain pipes"
				end
				s << "#{key}|#{PHP.serialize(value, assoc)}"
			end
		when Array
			var.each do |x|
				case x
				when Array
					if x.size == 2
						s << "#{x[0]}|#{PHP.serialize(x[1])}"
					else
						raise TypeError, "Array is not associative"
					end
				end
			end
		else
			raise TypeError, "Unable to serialize sessions with top level types other than Hash and associative Array"
		end
		s
	end # }}}

	# Returns an object containing the reconstituted data from serialized.
	#
	#   mixed = PHP.unserialize(string serialized, [hash classmap, [bool assoc]])
	#
	# If a PHP array (associative; like an ordered hash) is encountered, it
	# scans the keys; if they're all incrementing integers counting from 0,
	# it's unserialized as an Array, otherwise it's unserialized as a Hash.
	# Note: this will lose ordering.  To avoid this, specify assoc=true,
	# and it will be unserialized as an associative array: [[key,value],...]
	#
	# If a serialized object is encountered, the hash 'classmap' is searched for
	# the class name (as a symbol).  Since PHP classnames are not case-preserving,
	# this *must* be a .capitalize()d representation.  The value is expected
	# to be the class itself; i.e. something you could call .new on.
	#
	# If it's not found in 'classmap', the current constant namespace is searched,
	# and failing that, a new PHP::PhpObject (subclass of OpenStruct) is generated,
	# with the properties in the same order PHP provided; since PHP uses hashes
	# to represent attributes, this should be the same order they're specified
	# in PHP, but this is untested.
	#
	# each serialized attribute is sent to the new object using the respective
	# {attribute}=() method; you'll get a NameError if the method doesn't exist.
	#
	# Array, Hash, Fixnum, Float, True/FalseClass, NilClass and String should
	# be returned identically (i.e. foo == PHP.unserialize(PHP.serialize(foo))
	# for these types); Struct should be too, provided it's in the namespace
	# Module.const_get within unserialize() can see, or you gave it the same
	# name in the Struct.new(<structname>), otherwise you should provide it in
	# classmap.
	#
	# Note: StringIO is required for unserialize(); it's loaded as needed
	def PHP.unserialize(string, classmap = nil, assoc = false) # {{{
		if classmap == true or classmap == false
			assoc = classmap
			classmap = {}
		end
		classmap ||= {}

		ret = nil
		original_encoding = string.encoding
		state = SerializationState::ToUnserialize.new.tap { |state|
			state.assoc = assoc
			state.classmap = classmap
			state.original_encoding = original_encoding
		}

		string = StringIOReader.new(string.dup.force_encoding('BINARY'))
		while string.string[string.pos, 32] =~ /^(\w+)\|/ # session_name|serialized_data
			ret ||= {}
			string.pos += $&.size
			ret[$1] = PHP.do_unserialize(string, state)
		end

		ret || PHP.do_unserialize(string, state)
	end

	private

	def PHP.do_unserialize(string, state)
		val = nil
		this_value_index = (state.last_processed_value_index += 1)
		# determine a type
		type = string.read(2)[0,1]
		case type
			when 'a' # associative array, a:length:{[index][value]...}
				count = string.read_until('{').to_i
				val = Array.new
				count.times do |i|
					val << [do_unserialize(string, state), do_unserialize(string, state)]
				end
				string.read(1) # skip the ending }

				# now, we have an associative array, let's clean it up a bit...
				# arrays have all numeric indexes, in order; otherwise we assume a hash
				array = true
				i = 0
				val.each do |key,_|
					if key != i # wrong index -> assume hash
						array = false
						break
					end
					i += 1
				end

				val = val.map { |tuple|
					tuple.map { |it|
						it.kind_of?(String) ? it.force_encoding(state.original_encoding) : it
					}
				}

				if array
					val.map! {|_,value| value }
				elsif !state.assoc
					val = Hash[val]
				end

			when 'O' # object, O:length:"class":length:{[attribute][value]...}
				# class name (lowercase in PHP, grr)
				len = string.read_until(':').to_i + 3 # quotes, seperator
				klass_in_php = string.read(len)[1...-2]
				klass = klass_in_php.capitalize.intern # read it, kill useless quotes

				# read the attributes
				attrs = []
				len = string.read_until('{').to_i

				len.times do
					attr = (do_unserialize(string, state))
					attrs << [attr.intern, (attr << '=').intern, do_unserialize(string, state)]
				end
				string.read(1)

				val = nil
				# See if we need to map to a particular object
				if state.classmap.has_key?(klass)
					val = state.classmap[klass].new
				elsif Struct.const_defined?(klass) # Nope; see if there's a Struct
					state.classmap[klass] = val = Struct.const_get(klass)
					val = val.new
				else # Nope; see if there's a Constant
					begin
						state.classmap[klass] = val = Module.const_get(klass)

						val = val.new
					rescue NameError # Nope; make a new PhpObject
						val = PhpObject.new.tap { |php_obj|
							php_obj._php_classname = klass_in_php.to_s
						}
					end
				end

				attrs.each do |attr,attrassign,v|
					val.__send__(attrassign, v)
				end

			when 's' # string, s:length:"data";
				len = string.read_until(':').to_i + 3 # quotes, separator
				val = string.read(len)[1...-2].force_encoding(state.original_encoding) # read it, kill useless quotes

			when 'i' # integer, i:123
				val = string.read_until(';').to_i

			when 'd' # double (float), d:1.23
				val = string.read_until(';').to_f

			when 'N' # NULL, N;
				val = nil

			when 'b' # bool, b:0 or 1
				val = string.read(2)[0] == '1'

			when 'R', 'r' # reference to value/object, R:123 or r:123
				ref_index = string.read_until(';').to_i

				unless (0...(state.unserialized_values.size)).cover?(ref_index)
					raise TypeError, "Data part of R/r(Reference) refers to invalid index: #{ref_index.inspect}"
				end

				val = state.unserialized_values[ref_index]
			else
				raise TypeError, "Unable to unserialize type '#{type}'"
		end

		state.unserialized_values[this_value_index] = val

		val
	end # }}}
end
