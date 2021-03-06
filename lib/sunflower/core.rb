# coding: utf-8
require 'rest-client'
require 'json'
require 'cgi'

class Hash
	# Recursively, destructively merges two hashes that might contain further hashes and arrays.
	# Hashes are merged using #merge!; arrays are merged using #concat.
	# 
	# Named like this to prevent monkey-patching conflicts; is a monkey-patch because it is convenient.
	# Should be considered private to Sunflower and might disappear at any time.
	# Used in Sunflower#API_continued.
	# 
	# From http://stackoverflow.com/a/2277713 , slightly modified.
	def sunflower_recursive_merge!(other)
		other.keys.each do |k|
			if self[k].is_a?(Array) && other[k].is_a?(Array)
				self[k].concat(other[k])
			elsif self[k].is_a?(Hash) && other[k].is_a?(Hash)
				self[k].sunflower_recursive_merge!(other[k])
			else
				self[k] = other[k]
			end
		end
		self
	end
end

# Main class. To start working, you have to create new Sunflower:
#   s = Sunflower.new('en.wikipedia.org')
# And then log in:
#   s.login('Username','password')
#
# If you have ran setup, you can just use
#   s = Sunflower.new.login
#
# Then you can request data from API using #API method.
#
# To log data to file, use #log method (works like puts). Use RestClient.log=<io> to log all requests.
#
# You can use multiple Sunflowers at once, to work on multiple wikis.
class Sunflower
	VERSION = '0.5.11'
	
	INVALID_CHARS = %w(# < > [ ] | { })
	INVALID_CHARS_REGEX = Regexp.union *INVALID_CHARS
	
	# Path to user data file.
	def self.path
		File.join(ENV['HOME'], 'sunflower-userdata')
	end
	
	# Returns array of [url, username, password], or nil if userdata is unavailable or invalid.
	def self.read_userdata
		data = nil
		data = File.read(Sunflower.path).split(/\r?\n/).map{|i| i.strip} rescue nil
		
		if data && data.length==3 && data.all?{|a| a and a != ''}
			return data
		else
			return nil
		end
	end
	
	# Summary used when saving edits with this Sunflower.
	attr_accessor :summary
	# Whether to run #code_cleanup when calling #save.
	attr_accessor :always_do_code_cleanup
	# The URL this Sunflower works on, as provided as argument to #initialize.
	attr_reader :wikiURL, :api_endpoint
	# Siteinfo, as returned by API call.
	attr_accessor :siteinfo
	
	# Whether we are logged in.
	def logged_in?; @loggedin; end
	# Username if logged in; nil otherwise.
	attr_reader :username
	
	# Whether this user (if logged in) has bot rights.
	def is_bot?; @is_bot; end
	
	# Whether to output warning messages (using Kernel#warn). Defaults to true.
	attr_writer :warnings
	def warnings?; @warnings; end
	
	# Whether to output log messages (to a file named log.txt in current directory). Defaults to false.
	attr_writer :log
	def log?; @log; end
	
	# Used by #initialize to convert short identifiers such as "b:pl" to domains such as "pl.wikibooks.org".
	# Identifier is of the format "type:lang" or "lang:type" (see below for valid values).
	# 
	# Either or both parts can be ommitted; default type is "w", default lang is "en". 
	# (Since clashes are impossible, the colon can be ommitted in such cases as well.)
	# 
	# lang can be any valid language code. It is ignored for type == "meta" or "commons".
	# 
	# Valid values for type are the same as used for inter-wiki links, that is:
	# [w] Wikipedia
	# [b] Wikibooks
	# [n] Wikinews
	# [q] Wikiquote
	# [s] Wikisource
	# [v] Wikiversity
	# [wikt] Wiktionary
	# [species] Wikispecies
	# [commons] Wikimedia Commons
	# [meta] Wikimedia Meta-Wiki 
	def self.resolve_wikimedia_id id
		keys = id.split(':').select{|a| a and !a.empty? }
		
		raise ArgumentError, 'invalid format' if keys.length > 2
		
		type_map = {
			'b' => 'XX.wikibooks.org',
			'q' => 'XX.wikiquote.org',
			'n' => 'XX.wikinews.org',
			'w' => 'XX.wikipedia.org',
			'wikt' => 'XX.wiktionary.org',
			'species' => 'XX.wikispecies.org',
			'v' => 'XX.wikiversity.org',
			's' => 'XX.wikisource.org',
			'commons' => 'commons.wikimedia.org',
			'meta' => 'meta.wikimedia.org',
		}
		
		types, langs = keys.partition{|a| type_map.keys.include? a }
		type = types.first || 'w'
		lang = langs.first || 'en'
		
		return type_map[type].sub 'XX', lang
	end
	
	# Used by #initialize to cache siteinfo data.
	@@siteinfo = {}
	
	# Initialize a new Sunflower working on a wiki with given URL, for ex. "pl.wikipedia.org".
	# url can also be a shorthand identifier such as "b:pl" - see Sunflower.resolve_wikimedia_id for details.
	# 
	# There is currently one option available:
	# * api_endpoint: full URL to your api.php, if different than http://<url>/w/api.php (standard for WMF wikis)
	def initialize url=nil, opts={}
		if url.is_a? Hash
			url, opts = nil, url
		end
		
		if !url
			userdata = Sunflower.read_userdata()
			
			if userdata
				url = userdata[0]
			else
				raise Sunflower::Error, 'initialize: no URL supplied and no userdata found!'
			end
		end
		
		# find out the base URL for this wiki and its API endpoint
		# we joyfully assume that all URLs contain at least a single dot, which is incorrect, but oh well
		if url.include?('.')
			# a regular external wiki; use the RSD discovery mechanism to find out the endpoint
			@wikiURL = url
			# let's not pull in a HTML parsing library, this regex will do
			@api_endpoint = opts[:api_endpoint] || RestClient.get(@wikiURL).to_str[/<link rel="EditURI" type="application\/rsd\+xml" href="([^"]+)\?action=rsd"/, 1]
		else
			# probably a Wikimedia wiki shorthand
			@wikiURL = Sunflower.resolve_wikimedia_id(url)
			@api_endpoint = opts[:api_endpoint] || 'http://'+@wikiURL+'/w/api.php'
		end
		
		# handle protocol-relative URLs
		u = URI.parse(@api_endpoint)
		u.scheme ||= URI.parse(@wikiURL).scheme || 'http'
		@api_endpoint = u.to_s
		
		@warnings = true
		@log = false
		
		@loggedin = false
		@username = nil
		@is_bot = false
		
		@cookies = {}
		
		siprop = 'general|namespaces|namespacealiases|specialpagealiases|magicwords|interwikimap|dbrepllag|statistics|usergroups|extensions|fileextensions|rightsinfo|languages|skins|extensiontags|functionhooks|showhooks|variables'
		@@siteinfo[@api_endpoint] ||= self.API(action: 'query', meta: 'siteinfo', siprop: siprop)['query']
		@siteinfo = @@siteinfo[@api_endpoint]
		
		_build_ns_map
	end
	
	def inspect
		"#<Sunflower #{@loggedin ? @username : "[anon]"}@#{@wikiURL}#{@is_bot ? ' [bot]' : ''}>"
	end
	
	# Private. Massages data from siteinfo to be used for recognizing namespaces.
	def _build_ns_map
		@namespace_to_id = {} # all keys lowercase
		@namespace_id_to_canon = {}
		@namespace_id_to_local = {}
		
		@siteinfo['namespaces'].each_value do |h|
			next if h['content']
			
			id = h['id'].to_i
			@namespace_id_to_canon[id] = h['canonical']
			@namespace_id_to_local[id] = h['*']
			
			@namespace_to_id[ h['canonical'].downcase ] = id
			@namespace_to_id[ h['*'].downcase ] = id
		end
		@siteinfo['namespacealiases'].each do |h|
			@namespace_to_id[ h['*'].downcase ] = h['id'].to_i
		end
	end
	private :_build_ns_map
	
	# Call the API. Returns a hash of JSON response. Request can be a HTTP request string or a hash.
	def API request
		if request.is_a? String
			request += '&format=json'
		elsif request.is_a? Hash
			request = request.merge({format:'json'})
		end
		
		resp = RestClient.post(
			@api_endpoint,
			request,
			{:user_agent => "Sunflower #{VERSION} alpha", :cookies => @cookies}
		)
		JSON.parse resp.to_str
	end
	
	# Call the API. While more results are available via the xxcontinue parameter, call it again. 
	# 
	# Assumes action=query. 
	# 
	# By default returns an array of all API responses. Attempts to merge the responses
	# into a response that would have been returned if the limit was infinite
	# (merges the response hashes recursively using Hash#sunflower_recursive_merge!).
	# merge_on is the key of response["query-continue"] that contains the continuation data.
	# 
	# If limit given, will perform no more than this many API calls before returning.
	# If limit is 1, behaves exactly like #API.
	# 
	# Example: get list of all pages linking to Main Page:
	#   
	#   sunflower.API_continued "action=query&list=backlinks&bllimit=max&bltitle=Main_Page", 'backlinks', 'blcontinue'
	def API_continued request, merge_on, xxcontinue, limit=nil
		out = []
		
		# gather
		res = self.API(request)
		out << res
		while res['query-continue'] and (!limit || out.length < limit)
			api_endpoint = if request.is_a? String
				request + "&#{xxcontinue}=#{res["query-continue"][merge_on][xxcontinue]}"
			elsif request.is_a? Hash
				request.merge({xxcontinue => res["query-continue"][merge_on][xxcontinue]})
			end
			
			res = self.API(api_endpoint)
			out << res
		end
		
		# merge
		merged = out[0]
		out.drop(1).each do |cur|
			merged.sunflower_recursive_merge! cur
		end
		
		return merged
	end
	
	# Returns a Sunflower::Page with the given title belonging to this Sunflower.
	def page title
		Sunflower::Page.new title, self
	end
	
	# Log in using given info.
	def login user='', password=''
		if user=='' || password==''
			userdata = Sunflower.read_userdata()
			
			if userdata
				user = userdata[1] if user==''
				password = userdata[2] if password==''
			else
				raise Sunflower::Error, 'login: no user/pass supplied and no userdata found!'
			end
		end
		
		raise Sunflower::Error, 'bad username!' if user =~ INVALID_CHARS_REGEX
		
		
		# 1. get the login token
		response = RestClient.post(
			@api_endpoint, 
			"action=login&lgname=#{CGI.escape user}&lgpassword=#{CGI.escape password}&format=json",
			{:user_agent => "Sunflower #{VERSION} alpha"}
		)
		
		@cookies = response.cookies
		raise Sunflower::Error, 'unable to log in (no cookies received)!' if !@cookies or @cookies.empty?
		
		json = JSON.parse response.to_str
		token, prefix = (json['login']['lgtoken']||json['login']['token']), json['login']['cookieprefix']
		
		# 2. actually log in
		response = RestClient.post(
			@api_endpoint,
			"action=login&lgname=#{CGI.escape user}&lgpassword=#{CGI.escape password}&lgtoken=#{token}&format=json",
			{:user_agent => "Sunflower #{VERSION} alpha", :cookies => @cookies}
		)
		
		json = JSON.parse response.to_str
		
		@cookies = @cookies.merge(response.cookies)
		
		raise Sunflower::Error, 'unable to log in (no cookies received)!' if !@cookies or @cookies.empty?
		
		
		# 3. confirm you did log in by checking the watchlist.
		@loggedin=true
		r=self.API('action=query&list=watchlistraw')
		if r['error'] && r['error']['code']=='wrnotloggedin'
			@loggedin=false
			raise Sunflower::Error, 'unable to log in!'
		end
		
		# set the username
		@username = user
		
		# 4. check bot rights
		r=self.API('action=query&list=allusers&aulimit=1&augroup=bot&aufrom='+(CGI.escape user))
		unless r['query']['allusers'][0] && r['query']['allusers'][0]['name']==user
			warn 'Sunflower - this user does not have bot rights!' if @warnings
			@is_bot=false
		else
			@is_bot=true
		end
		
		return self
	end
	
	# Log message to a file named log.txt in current directory, if logging is enabled. See #log= / #log?.
	def log message
		File.open('log.txt','a'){|f| f.puts message} if @log
	end
	
	# Cleans up underscores, percent-encoding and title-casing in title (with optional anchor).
	def cleanup_title title, preserve_case=false, preserve_colon=false
		# strip unicode bidi junk
		title = title.gsub /[\u200e\u200f\u202a\u202b\u202c\u202d\u202e]/, ''
		# strip unicode spaces
		title = title.gsub /[\u00a0\u1680\u180e\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+/, ' '
		
		return '' if title.strip == ''
		
		name, anchor = title.split '#', 2
		
		# CGI.unescape also changes pluses to spaces; code borrowed from there
		unescape = lambda{|a| a.gsub(/((?:%[0-9a-fA-F]{2})+)/){ [$1.delete('%')].pack('H*').force_encoding($1.encoding) } }
		
		ns = nil
		name = unescape.call(name).gsub(/[ _]+/, ' ').strip
		anchor = unescape.call(anchor.gsub(/\.([0-9a-fA-F]{2})/, '%\1')).gsub(/[ _]+/, ' ').strip if anchor
		
		leading_colon = name[0]==':'
		name = name.sub(/^:\s*/, '') if leading_colon
		leading_colon = false if !preserve_colon
		
		# FIXME unicode? downcase, upcase
		
		if name.include? ':'
			maybe_ns, part_name = name.split ':', 2
			if ns_id = @namespace_to_id[maybe_ns.strip.downcase]
				ns, name = @namespace_id_to_local[ns_id], part_name.strip
			end
		end
		
		name[0] = name[0].upcase if !preserve_case and @siteinfo["general"]["case"] == "first-letter"
		
		return [leading_colon ? ':' : nil,  ns ? "#{ns}:" : nil,  name,  anchor ? "##{anchor}" : nil].join ''
	end
	
	# Returns the localized namespace name for ns, which may be namespace number, canonical name, or any namespace alias.
	# 
	# Returns nil if passed an invalid namespace.
	def ns_local_for ns
		case ns
		when Numeric
			@namespace_id_to_local[ns.to_i]
		when String
			@namespace_id_to_local[ @namespace_to_id[cleanup_title(ns).downcase] ]
		end
	end
	
	# Like #ns_local_for, but returns canonical (English) name.
	def ns_canon_for ns
		case ns
		when Numeric
			@namespace_id_to_canon[ns.to_i]
		when String
			@namespace_id_to_canon[ @namespace_to_id[cleanup_title(ns).downcase] ]
		end
	end
	
	# Returns a regular expression that will match given namespace. Rules for input like #ns_local_for.
	# 
	# Does NOT handle percent-encoding and underscores. Use #cleanup_title to canonicalize the namespace first.
	def ns_regex_for ns
		id = ns.is_a?(Numeric) ? ns.to_i : @namespace_to_id[cleanup_title(ns).downcase]
		return nil if !id
		
		/#{@namespace_to_id.to_a.select{|a| a[1] == id }.map{|a| Regexp.escape a[0] }.join '|' }/i
	end
end

# Class representing a single Wiki page. To load specified page, use #new. To save it back, use #save.
class Sunflower::Page
	# Characters which MediaWiki does not permit in page title.
	INVALID_CHARS = %w(# < > [ ] | { })
	# Regex matching characters which MediaWiki does not permit in page title.
	INVALID_CHARS_REGEX = Regexp.union *INVALID_CHARS
	
	# The Sunflower instance this page belongs to.
	attr_reader :sunflower
	
	# The current text of the page. Lazy-loaded.
	attr_accessor :text
	# The text of the page, as of when it was loaded. Lazy-loaded.
	attr_reader :orig_text
	
	# Page title, as passed to #initialize and cleaned by Sunflower#cleanup_title.
	# Real page title as canonicalized by MediaWiki software can be accessed via #real_title
	# (but it should always be the same).
	attr_reader :title
	
	# Value of given attribute, as returned by API call prop=info for this page. Lazy-loaded.
	attr_reader :pageid, :ns, :touched, :lastrevid, :counter, :length, :starttimestamp, :edittoken, :protection
	# Value of `title` attribute, as returned by API call prop=info for this page. Lazy-loaded. See #title.
	attr_reader :real_title
	
	# Whether this datum is already loaded. Can be set to true to suppress loading
	# (used e.g. by Sunflower::List#pages_preloaded)
	attr_accessor :preloaded_text, :preloaded_attrs
	
	# calling any of these accessors will fetch the data.
	# getters...
	[:pageid, :ns, :real_title, :touched, :lastrevid, :counter, :length, :starttimestamp, :edittoken, :protection].each do |meth|
		remove_method meth # to avoid warnings when running with ruby -w
		define_method meth do
			preload_attrs unless @preloaded_attrs
			instance_variable_get "@#{meth}"
		end
	end
	[:text, :orig_text].each do |meth|
		remove_method meth # to avoid warnings when running with ruby -w
		define_method meth do
			preload_text unless @preloaded_text
			instance_variable_get "@#{meth}"
		end
	end
	# setters...
	[:text=].each do |meth|
		remove_method meth # to avoid warnings when running with ruby -w
		define_method meth do |a|
			preload_text unless @preloaded_text
			instance_variable_set "@#{meth.to_s.chop}", a
		end
	end
	
	# Load the specified page. 
	# Only the text will be immediately loaded - attributes and edit token will be loaded when needed, or when you call #preload_attrs.
	# 
	# If you are using multiple Sunflowers, you have to specify which one this page belongs to using the second argument of function.
	# You can pass either a Sunflower object, wiki URL, or a shorthand id as specified in Sunflower.resolve_wikimedia_id.
	def initialize title='', url=''
		raise Sunflower::Error, 'title invalid: '+title if title =~ INVALID_CHARS_REGEX
		
		case url
		when Sunflower
			@sunflower = url
		when '', nil
			count = ObjectSpace.each_object(Sunflower){|o| @sunflower=o}
			raise Sunflower::Error, 'no Sunflowers present' if count==0
			raise Sunflower::Error, 'you must pass wiki name if using multiple Sunflowers at once' if count>1
		else
			url = (url.include?('.') ? url : Sunflower.resolve_wikimedia_id(url))
			ObjectSpace.each_object(Sunflower){|o| @sunflower=o if o.wikiURL==url}
			raise Sunflower::Error, "no Sunflower for #{url}" if !@sunflower
		end
		
		@title = @sunflower.cleanup_title title
		
		@preloaded_text = false
		@preloaded_attrs = false
	end
	
	# Load the text of this page. Semi-private.
	def preload_text
		if title == ''
			@text = ''
		else
			r = @sunflower.API('action=query&prop=revisions&rvprop=content&titles='+CGI.escape(@title))
			r = r['query']['pages'].values.first
			if r['missing']
				@text = ''
			elsif r['invalid']
				raise Sunflower::Error, 'title invalid: '+@title
			else
				@text = r['revisions'][0]['*']
			end
		end
		
		@orig_text = @text.dup
		
		@preloaded_text = true
	end
	
	# Load the metadata associated with this page. Semi-private.
	def preload_attrs
		r = @sunflower.API('action=query&prop=info&inprop=protection&intoken=edit&titles='+CGI.escape(@title))
		r = r['query']['pages'].values.first
		r.each{|key, value|
			key = 'real_title' if key == 'title'
			self.instance_variable_set('@'+key, value)
		}
		
		@preloaded_attrs = true
	end
	
	# Save the current text of this page to file (which can be either a filename or an IO).
	def dump_to file
		if file.respond_to? :write #probably file or IO
			file.write @text
		else #filename?
			File.open(file.to_s, 'w'){|f| f.write @text}
		end
	end
	
	# Save the current text of this page to a file whose name is based on page title, with non-alphanumeric characters stripped.
	def dump
		self.dump_to @title.gsub(/[^a-zA-Z0-9\-]/,'_')+'.txt'
	end
	
	# Save the modifications to this page, possibly under a different title. Default summary is this page's Sunflower's summary (see Sunflower#summary=). Default title is the current title.
	# 
	# Will not perform API request if no changes were made.
	# 
	# Will call #code_cleanup if Sunflower#always_do_code_cleanup is set.
	# 
	# Returns the JSON result of API call or nil when API call was not made.
	def save title=@title, summary=@sunflower.summary
		preload_attrs unless @preloaded_attrs
		
		raise Sunflower::Error, 'title invalid: '+title if title =~ INVALID_CHARS_REGEX
		raise Sunflower::Error, 'empty or no summary!' if !summary or summary==''
		
		if @orig_text==@text && title==@title
			@sunflower.log('Page '+title+' not saved - no changes.')
			return nil
		end
		
		
		self.code_cleanup if @sunflower.always_do_code_cleanup && self.respond_to?('code_cleanup')
		
		return @sunflower.API("action=edit&bot=1&title=#{CGI.escape(title)}&text=#{CGI.escape(@text)}&summary=#{CGI.escape(summary)}&token=#{CGI.escape(@edittoken)}")
	end
	alias :put :save
	
	def self.get title, wiki=''
		self.new(title, wiki)
	end
	
	def self.load title, wiki=''
		self.new(title, wiki)
	end
end

# For backwards compatibility. Deprecated.
class Page # :nodoc:
	class << self
		def new *a
			warn "warning: toplevel Page class has been renamed to Sunflower::Page, this alias will be removed in v0.6"
			Sunflower::Page.new *a
		end
		alias get new
		alias load new
	end
end

# For backwards compatibility. Deprecated.
# 
# We use inheritance shenanigans to keep the usage in "begin ... rescue ... end" working.
class SunflowerError < StandardError # :nodoc:
	%w[== backtrace exception inspect message set_backtrace to_s].each do |meth|
		define_method meth.to_sym do |*a, &b|
			if self.class == SunflowerError and !@warned
				warn "warning: toplevel SunflowerError class has been renamed to Sunflower::Error, this alias will be removed in v0.6"
				@warned = true
			end
			
			super *a, &b
		end
	end
	
	class << self
		def new *a
			warn "warning: toplevel SunflowerError class has been renamed to Sunflower::Error, this alias will be removed in v0.6" if self == SunflowerError
			super
		end
		def exception *a
			warn "warning: toplevel SunflowerError class has been renamed to Sunflower::Error, this alias will be removed in v0.6" if self == SunflowerError
			super
		end
	end
end


# Represents an error raised by Sunflower.
class Sunflower::Error < SunflowerError; end
