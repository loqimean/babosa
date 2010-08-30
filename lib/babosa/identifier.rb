# encoding: utf-8
module Babosa

  # This class provides some string-manipulation methods specific to slugs.
  #
  # Note that this class includes many "bang methods" such as {#clean!} and
  # {#normalize!} that perform actions on the string in-place. Each of these
  # methods has a corresponding "bangless" method (i.e., +Identifier#clean!+
  # and +Identifier#clean+) which does not appear in the documentation because
  # it is generated dynamically.
  #
  # All of the bang methods return an instance of String, while the bangless
  # versions return an instance of Babosa::Identifier, so that calls to methods
  # specific to this class can be chained:
  #
  #   string = Identifier.new("hello world")
  #   string.with_separators! # => "hello-world"
  #   string.with_separators  # => <Babosa::Identifier:0x000001013e1590 @wrapped_string="hello-world">
  #
  # @see http://www.utf8-chartable.de/unicode-utf8-table.pl?utf8=dec Unicode character table
  class Identifier

    attr_reader :wrapped_string
    alias to_s wrapped_string

    @@utf8_proxy = if Babosa.jruby15?
      UTF8::JavaProxy
    elsif defined? Unicode
      UTF8::UnicodeProxy
    elsif defined? ActiveSupport
      UTF8::ActiveSupportProxy
    else
      UTF8::DumbProxy
    end

    # Return the proxy used for UTF-8 support.
    # @see Babosa::UTF8::UTF8Proxy
    def self.utf8_proxy
      @@utf8_proxy
    end

    # Set a proxy object used for UTF-8 support.
    # @see Babosa::UTF8::UTF8Proxy
    def self.utf8_proxy=(obj)
      @@utf8_proxy = obj
    end

    def method_missing(symbol, *args, &block)
      @wrapped_string.__send__(symbol, *args, &block)
    end

    # @param string [#to_s] The string to use as the basis of the Identifier.
    def initialize(string)
      @wrapped_string = string.to_s
      tidy_bytes!
      normalize_utf8!
    end

    # Approximate an ASCII string. This works only for Western strings using
    # characters that are Roman-alphabet characters + diacritics. Non-letter
    # characters are left unmodified.
    #
    #   string = Identifier.new "Łódź, Poland"
    #   string.transliterate                 # => "Lodz, Poland"
    #   string = Identifier.new "日本"
    #   string.transliterate                 # => "日本"
    #
    # You can pass any key(s) from +Characters.approximations+ as arguments. This allows
    # for contextual approximations. Danish, German, Serbian and Spanish are currently
    # supported.
    #
    #   string = Identifier.new "Jürgen Müller"
    #   string.transliterate                 # => "Jurgen Muller"
    #   string.transliterate :german         # => "Juergen Mueller"
    #   string = Identifier.new "¡Feliz año!"
    #   string.transliterate                 # => "¡Feliz ano!"
    #   string.transliterate :spanish        # => "¡Feliz anio!"
    #
    # You can modify the built-in approximations, or add your own:
    #
    #   # Make Spanish use "nh" rather than "nn"
    #   Babosa::Characters.add_approximations(:spanish, "ñ" => "nh")
    #
    # Notice that this method does not simply convert to ASCII; if you want
    # to remove non-ASCII characters such as "¡" and "¿", use {#to_ascii!}:
    #
    #   string.transliterate!(:spanish)       # => "¡Feliz anio!"
    #   string.transliterate!                 # => "Feliz anio!"
    # @param *args <Symbol>
    # @return String
    def transliterate!(transliterations = {})
      if transliterations.kind_of? Symbol
        transliterations = Characters.approximations[transliterations]
      else
        transliterations ||= {}
      end
      @wrapped_string = unpack("U*").map { |char| approx_char(char, transliterations) }.flatten.pack("U*")
    end

    # Converts dashes to spaces, removes leading and trailing spaces, and
    # replaces multiple whitespace characters with a single space.
    # @return String
    def clean!
      @wrapped_string = @wrapped_string.gsub("-", " ").squeeze(" ").strip
    end

    # Remove any non-word characters. For this library's purposes, this means
    # anything other than letters, numbers, spaces, newlines and linefeeds.
    # @return String
    def word_chars!
      @wrapped_string = (unpack("U*") - Characters.strippable).pack("U*")
    end

    # Normalize the string for use as a URL slug. Note that in this context,
    # +normalize+ means, strip, remove non-letters/numbers, downcasing,
    # truncating to 255 bytes and converting whitespace to dashes.
    # @param Options
    # @return String
    def normalize!(options = nil)
      # Handle deprecated usage
      if options == true
        warn "#normalize! now takes a hash of options rather than a boolean"
        options = default_normalize_options.merge(:to_ascii => true)
      else
        options = default_normalize_options.merge(options || {})
      end
      if options[:transliterate]
        transliterate!(*options[:transliterations])
      end
      to_ascii! if options[:to_ascii]
      clean!
      word_chars!
      clean!
      downcase!
      truncate_bytes!(options[:max_length])
      with_separators!(options[:separator])
    end

    # Normalize a string so that it can safely be used as a Ruby method name.
    def to_ruby_method!
      normalize!(:to_ascii => true, :separator => "_")
    end

    # Delete any non-ascii characters.
    # @return String
    def to_ascii!
      @wrapped_string = @wrapped_string.gsub(/[^\x00-\x7f]/u, '')
    end

    # Truncate the string to +max+ characters.
    # @example
    #   "üéøá".to_identifier.truncate(3) #=> "üéø"
    # @return String
    def truncate!(max)
      @wrapped_string = unpack("U*")[0...max].pack("U*")
    end

    # Truncate the string to +max+ bytes. This can be useful for ensuring that
    # a UTF-8 string will always fit into a database column with a certain max
    # byte length. The resulting string may be less than +max+ if the string must
    # be truncated at a multibyte character boundary.
    # @example
    #   "üéøá".to_identifier.truncate_bytes(3) #=> "ü"
    # @return String
    def truncate_bytes!(max)
      return @wrapped_string if @wrapped_string.bytesize <= max
      curr = 0
      new = []
      unpack("U*").each do |char|
        break if curr > max
        char = [char].pack("U")
        curr += char.bytesize
        if curr <= max
          new << char
        end
      end
      @wrapped_string = new.join
    end

    # Replaces whitespace with dashes ("-").
    # @return String
    def with_separators!(char = "-")
      @wrapped_string = @wrapped_string.gsub(/\s/u, char)
    end

    # Perform UTF-8 sensitive upcasing.
    # @return String
    def upcase!
      @wrapped_string = @@utf8_proxy.upcase(@wrapped_string)
    end

    # Perform UTF-8 sensitive downcasing.
    # @return String
    def downcase!
      @wrapped_string = @@utf8_proxy.downcase(@wrapped_string)
    end

    # Perform Unicode composition on the wrapped string.
    # @return String
    def normalize_utf8!
      @wrapped_string = @@utf8_proxy.normalize_utf8(@wrapped_string)
    end

    # Attempt to convert characters encoded using CP1252 and IS0-8859-1 to
    # UTF-8.
    # @return String
    def tidy_bytes!
      @wrapped_string = @@utf8_proxy.tidy_bytes(@wrapped_string)
    end

    %w[transliterate clean downcase word_chars normalize normalize_utf8
      tidy_bytes to_ascii truncate truncate_bytes upcase with_separators].each do |method|
      class_eval(<<-EOM, __FILE__, __LINE__ +1)
        def #{method}(*args)
          send_to_new_instance(:#{method}!, *args)
        end
      EOM
    end

    def to_identifier
      self
    end

    # The default options for {#normalize!}. Override to set your own defaults.
    def default_normalize_options
      {:transliterate => true, :max_length => 255, :separator => "-"}
    end

    alias approximate_ascii transliterate
    alias approximate_ascii! transliterate!
    alias with_dashes with_separators
    alias with_dashes! with_separators!
    alias to_slug to_identifier

    private

    # Look up the character's approximation in the configured maps.
    def approx_char(char, transliterations = {})
      transliterations[char] or Characters.approximations[:latin][char] or char
    end

    # Used as the basis of the bangless methods.
    def send_to_new_instance(*args)
      id = Identifier.allocate
      id.instance_variable_set :@wrapped_string, to_s
      id.send(*args)
      id
    end
  end

  # Identifier is aliased as SlugString to support older versions of FriendlyId.
  SlugString = Identifier
end
