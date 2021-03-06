require "rack"

class Cuba
  class RedefinitionError < StandardError; end

  @@methods = []

  class << self
    undef method_added
  end

  def self.method_added(meth)
    @@methods << meth
  end

  def self.reset!
    @app = nil
    @prototype = nil
  end

  def self.app
    @app ||= Rack::Builder.new
  end

  def self.use(middleware, *args, &block)
    app.use(middleware, *args, &block)
  end

  def self.define(&block)
    app.run new(&block)
  end

  def self.prototype
    @prototype ||= app.to_app
  end

  def self.call(env)
    prototype.call(env)
  end

  def self.plugin(mixin)
    include mixin
    extend  mixin::ClassMethods if defined?(mixin::ClassMethods)

    mixin.setup(self) if mixin.respond_to?(:setup)
  end

  def self.settings
    @settings ||= {}
  end

  def self.inherited(child)
    child.settings.replace(settings)
  end

  attr :env
  attr :req
  attr :res
  attr :captures

  def initialize(&blk)
    @blk = blk
    @captures = []
  end

  def settings
    self.class.settings
  end

  def call(env)
    dup.call!(env)
  end

  def call!(env)
    @env = env
    @req = Rack::Request.new(env)
    @res = Rack::Response.new

    # This `catch` statement will either receive a
    # rack response tuple via a `halt`, or will
    # fall back to issuing a 404.
    #
    # When it `catch`es a throw, the return value
    # of this whole `_call` method will be the
    # rack response tuple, which is exactly what we want.
    catch(:halt) do
      instance_eval(&@blk)

      res.status = 404
      res.finish
    end
  end

  def session
    env["rack.session"] || raise(RuntimeError,
      "You're missing a session handler. You can get started " +
      "by adding Cuba.use Rack::Session::Cookie")
  end

  # The heart of the path / verb / any condition matching.
  #
  # @example
  #
  #   on get do
  #     res.write "GET"
  #   end
  #
  #   on get, "signup" do
  #     res.write "Signup
  #   end
  #
  #   on "user/:id" do |uid|
  #     res.write "User: #{uid}"
  #   end
  #
  #   on "styles", extension("css") do |file|
  #     res.write render("styles/#{file}.sass")
  #   end
  #
  def on(*args, &block)
    try do
      # For every block, we make sure to reset captures so that
      # nesting matchers won't mess with each other's captures.
      @captures = []

      # We stop evaluation of this entire matcher unless
      # each and every `arg` defined for this matcher evaluates
      # to a non-false value.
      #
      # Short circuit examples:
      #    on true, false do
      #
      #    # PATH_INFO=/user
      #    on true, "signup"
      return unless args.all? { |arg| match(arg) }

      # The captures we yield here were generated and assembled
      # by evaluating each of the `arg`s above. Most of these
      # are carried out by #consume.
      yield(*captures)

      halt res.finish
    end
  end

  # @private Used internally by #on to ensure that SCRIPT_NAME and
  #          PATH_INFO are reset to their proper values.
  def try
    script, path = env["SCRIPT_NAME"], env["PATH_INFO"]

    yield

  ensure
    env["SCRIPT_NAME"], env["PATH_INFO"] = script, path
  end
  private :try

  def consume(pattern)
    return unless match = env["PATH_INFO"].match(/\A\/(#{pattern})((?:\/|\z))/)

    path, *vars = match.captures

    env["SCRIPT_NAME"] += "/#{path}"
    env["PATH_INFO"] = "#{vars.pop}#{match.post_match}"

    captures.push(*vars)
  end
  private :consume

  def match(matcher, segment = "([^\\/]+)")
    case matcher
    when String then consume(matcher.gsub(/:\w+/, segment))
    when Regexp then consume(matcher)
    when Symbol then consume(segment)
    when Proc   then matcher.call
    else
      matcher
    end
  end

  # A matcher for files with a certain extension.
  #
  # @example
  #   # PATH_INFO=/style/app.css
  #   on "style", extension("css") do |file|
  #     res.write file # writes app
  #   end
  def extension(ext = "\\w+")
    lambda { consume("([^\\/]+?)\.#{ext}\\z") }
  end

  # Used to ensure that certain request parameters are present. Acts like a
  # precondition / assertion for your route.
  #
  # @example
  #   # POST with data like user[fname]=John&user[lname]=Doe
  #   on "signup", param("user") do |atts|
  #     User.create(atts)
  #   end
  def param(key)
    lambda { captures << req[key] unless req[key].to_s.empty? }
  end

  def header(key)
    lambda { env[key.upcase.tr("-","_")] }
  end

  # Useful for matching against the request host (i.e. HTTP_HOST).
  #
  # @example
  #   on host("account1.example.com"), "api" do
  #     res.write "You have reached the API of account1."
  #   end
  def host(hostname)
    hostname === req.host
  end

  # If you want to match against the HTTP_ACCEPT value.
  #
  # @example
  #   # HTTP_ACCEPT=application/xml
  #   on accept("application/xml") do
  #     # automatically set to application/xml.
  #     res.write res["Content-Type"]
  #   end
  def accept(mimetype)
    lambda do
      String(env["HTTP_ACCEPT"]).split(",").any? { |s| s.strip == mimetype } and
        res["Content-Type"] = mimetype
    end
  end

  # Syntactic sugar for providing catch-all matches.
  #
  # @example
  #   on default do
  #     res.write "404"
  #   end
  def default
    true
  end

  # Syntatic sugar for providing HTTP Verb matching.
  #
  # @example
  #   on get, "signup" do
  #   end
  #
  #   on post, "signup" do
  #   end
  def get;    req.get?    end
  def post;   req.post?   end
  def put;    req.put?    end
  def delete; req.delete? end

  # If you want to halt the processing of an existing handler
  # and continue it via a different handler.
  #
  # @example
  #   def redirect(*args)
  #     run Cuba.new { on(default) { res.redirect(*args) }}
  #   end
  #
  #   on "account" do
  #     redirect "/login" unless session["uid"]
  #
  #     res.write "Super secure account info."
  #   end
  def run(app)
    halt app.call(req.env)
  end

  def halt(response)
    throw :halt, response
  end

  class << self
    undef method_added
  end

  # In order to prevent people from overriding the standard Cuba
  # methods like `get`, `put`, etc, we add this as a safety measure.
  def self.method_added(meth)
    if @@methods.include?(meth)
      raise RedefinitionError, meth
    end
  end
end
