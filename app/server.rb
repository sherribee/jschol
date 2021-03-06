# Sample application foundation for eschol5 - see README.md for more info

# Use bundler to keep dependencies local
require 'rubygems'
require 'bundler/setup'

###################################################################################################
# External gems we need
require 'aws-sdk'
require 'cgi'
require 'digest'
require 'json'
require 'logger'
require 'mimemagic'
require 'net/http'
require 'open-uri'
require 'pp'
require 'sanitize'
require 'sequel'
require 'sinatra'
require 'sinatra/streaming'
require 'yaml'
require 'socksify'
require 'socket'

# Make puts thread-safe, and flush after every puts.
$stdoutMutex = Mutex.new
def puts(*args)
  $stdoutMutex.synchronize {
    #STDOUT.print Thread.current
    super(*args)
    STDOUT.flush
  }
end

# Moneky patch for nasty problem in Sinatra contrib library "Streaming": it calls a thing
# called "errback" that doesn't exist.
module Sinatra
  module Streaming
    module Stream
      def self.extended(obj)
        obj.closed, obj.lineno, obj.pos = false, 0, 0
        obj.callback { obj.closed = true }
        #THISISTHEFIX# obj.errback  { obj.closed = true }
      end
    end
  end
end

# Make it clear where the new session starts in the log file.
puts "\n\n=====================================================================================\n"

def waitForSocks(host, port)
  first = true
  begin
    sock = TCPSocket.new(host, port)
    sock.close
  rescue Errno::ECONNREFUSED
    first and puts("Waiting for SOCKS proxy to start.")
    first = false
    sleep 0.5
    retry
  end
end

def ensureConnect(dbConfig)
  if TCPSocket::socks_port
    SocksMysql.new(dbConfig)
  end
  db = Sequel.connect(dbConfig)
  n = db.fetch("SHOW TABLE STATUS").all.length
  n > 0 or raise("Failed to connect to db.")
  return db
end

# Use the Sequel gem to get object-relational mapping, connection pooling, thread safety, etc.
# If specified, use SOCKS proxy for all connections (including database).
escholDbConfig = YAML.load_file("config/database.yaml")
ojsDbConfig = YAML.load_file("config/ojsDb.yaml")
if File.exist? "config/socks.yaml"
  # Configure socksify for all TCP connections. Jump through hoops for MySQL to use it too.
  socksPort = YAML.load_file("config/socks.yaml")['port']
  waitForSocks("127.0.0.1", socksPort)
  TCPSocket::socks_server = "127.0.0.1"
  TCPSocket::socks_port = socksPort
  require_relative 'socksMysql'
end
puts "Connecting to eschol DB.    "
DB = ensureConnect(escholDbConfig)
#DB.loggers << Logger.new('server.sql_log')  # Enable to debug SQL queries on main db
puts "Connecting to OJS DB.       "
OJS_DB = ensureConnect(ojsDbConfig)
#OJS_DB.loggers << Logger.new('ojs.sql_log')  # Enable to debug SQL queries on OJS db

# Need credentials for fetching content files from MrtExpress
$mrtExpressConfig = YAML.load_file("config/mrtExpress.yaml")

# S3 API client
puts "Connecting to S3.           "
$s3Config = OpenStruct.new(YAML.load_file("config/s3.yaml"))
$s3Client = Aws::S3::Client.new(region: $s3Config.region)
$s3Bucket = Aws::S3::Bucket.new($s3Config.bucket, client: $s3Client)

# Internal modules to implement specific pages and functionality
require_relative 'dbCache'
require_relative 'hierarchy'
require_relative 'listItemViews'
require_relative 'searchApi'
require_relative 'queueWithTimeout'
require_relative 'unitPages'
require_relative 'citation'
require_relative 'loginApi'

# Sinatra configuration
configure do
  # Don't use Webrick, as sinatra-websocket requires 'thin', and 'thin' is better anyway.
  set :server, 'thin'
  # We like to use the 'app' folder for all our static resources
  set :public_folder, Proc.new { root }

  set :show_exceptions, false
end

# Compress responses
## NO: This fails when streaming files. Not sure why yet.
#use Rack::Deflater

# For general app development, set DO_ISO to false. For real deployment, set to true
DO_ISO = File.exist?("config/do_iso")

###################################################################################################
# Model classes for easy interaction with the database.
#
# For more info on the database schema, see contents of migrations/ directory, and for a more
# graphical version, see:
#
# https://docs.google.com/drawings/d/1gCi8l7qteyy06nR5Ol2vCknh9Juo-0j91VGGyeWbXqI/edit

class Unit < Sequel::Model
  unrestrict_primary_key
  one_to_many :unit_hier,     :class=>:UnitHier, :key=>:unit_id
  one_to_many :ancestor_hier, :class=>:UnitHier, :key=>:ancestor_unit
end

class UnitHier < Sequel::Model(:unit_hier)
  unrestrict_primary_key
  many_to_one :unit,          :class=>:Unit
  many_to_one :ancestor,      :class=>:Unit, :key=>:ancestor_unit
end

class UnitItem < Sequel::Model
  unrestrict_primary_key
end

class Item < Sequel::Model
  unrestrict_primary_key
end

class ItemAuthors < Sequel::Model(:item_authors)
  unrestrict_primary_key
end

class Issue < Sequel::Model
end

class Section < Sequel::Model
end

class Page < Sequel::Model
end

class Widget < Sequel::Model
end

##################################################################################################
# Thread synchronization class
class Event
  def initialize
    @lock = Mutex.new
    @cond = ConditionVariable.new
    @flag = false
  end
  def set
    @lock.synchronize do
      @flag = true
      @cond.broadcast
   end
  end
  def wait
    @lock.synchronize do
      if not @flag
        @cond.wait(@lock)
      end
    end
  end
end

##################################################################################################
# Database caches for speed. We check every 30 seconds for changes. These tables change infrequently.

$unitsHash, $hierByUnit, $hierByAncestor, $activeCampuses, $oruAncestors, $campusJournals,
  $statsCampusPubs, $statsCampusOrus, $statsCampusJournals = nil, nil, nil, nil, nil, nil, nil, nil, nil
$cachesFilled = Event.new
Thread.new {
  prevTime = nil
  while true
    utime = nil
    DB.fetch("SHOW TABLE STATUS WHERE Name in ('units', 'unit_hier')").each { |row|
      if row[:Update_time] && (!utime || row[:Update_time] > utime)
        utime = row[:Update_time]
      end
    }
    if !utime || utime != prevTime
      puts "Filling caches.           "
      $unitsHash = getUnitsHash
      $hierByUnit = getHierByUnit
      $hierByAncestor = getHierByAncestor
      $activeCampuses = getActiveCampuses
      $oruAncestors = getOruAncestors
      $campusJournals = getJournalsPerCampus    # Used for browse pages

      #####################################################################
      # STATISTICS
      # These are dependent on instantation of $activeCampuses

      # HOME PAGE statistics
      # ToDo:
      $statsViews = countViews
      $statsDownloads = countDownloads
      $statsOpenItems = countOpenItems
      $statsOrus = countOrus
      $statsItems =  countItems
      $statsThesesDiss = countThesisDiss
      $statsBooks = countBooks
      $statsEscholJournals = countEscholJournals
      $statsStudentJournals = countStudentJournals

      # BROWSE PAGE statistics
      $statsCampusPubs = getPubStatsPerCampus
      $statsCampusOrus = getOruStatsPerCampus
      $statsCampusJournals = getJournalStatsPerCampus
      $cachesFilled.set
      prevTime = utime
    end
    sleep 30
  end
}
$cachesFilled.wait

###################################################################################################
# ISOMORPHIC JAVASCRIPT
# =====================
#
# Using a Javascript front-end framework like React has a couple downsides: First, it makes the
# site unusable by users who have Javascript turned off. Second, not all crawlers can or do run
# your javascript, and so it might make the site invisible to them.
#
# The solution is so-called "isomorphic Javascript". Basically we run React not only in the
# browser but also on the server. When the page initially loads, we generate the initial HTML
# that React will eventually generate once it fully initializes on the client side, and we send
# that HTML as a starting point. When React starts up on the client, it verifies that the HTML
# is the same (and issues a console warning if not).
#
# How do we run React on the server? We keep a little Node Express server running on a differnet
# port than the main app, and when we need to load a page we feed it the initial data, it runs
# the appropriate React templates, and returns us the HTML.
#
# In this way, the user gets a speedy initial load and can use some of the site features without
# javascript, and crawlers have an easy time seeing everything the users see.
###################################################################################################

###################################################################################################
# Simple up-ness check
get "/check" do
  return "ok"
end

###################################################################################################
# Sanitize incoming filenames before applying them to the filesystem. In particular, prevent
# attacks using "../" as part of the path.
def sanitizeFilePath(path)
  path = path.gsub(/[^-a-z A-Z0-9_.\/]/, '_').split("/").map { |part|
    part.sub(/^\.+/, '_').sub(/\.+$/, '_')
  }.join('/')
end

###################################################################################################
class Fetcher
  def start(uri)
    # We have to fetch the file in a different thread, because it needs to keep the HTTP request
    # open in that thread while we return the status code to Sinatra. Then the remaining data can
    # be streamed from the thread to Sinatra.
    puts "Content fetch: #{uri}."
    @queue = QueueWithTimeout.new
    Thread.new do
      begin
        # Now jump through Net::HTTP's hijinks to actually fetch the file.
        Net::HTTP.start(uri.host, uri.port, :use_ssl => (uri.scheme == 'https')) do |http|
          req = Net::HTTP::Get.new(uri.request_uri)
          req.basic_auth $mrtExpressConfig['username'], $mrtExpressConfig['password']
          http.request(req) do |response|
            @queue << [response.code, response.message]
            if response.code == "200"
              response.read_body { |chunk| @queue << chunk }
            else
              puts "Error: Response to #{uri} was HTTP #{response.code}: #{response.message.inspect}"
            end
          end
        end
      rescue Exception => e
        puts "Fetch exception: #{e}"
      ensure
        @queue << nil  # mark end-of-data
      end
    end

    # Wait for the status code to come back from the fetch thread.
    code, msg = @queue.pop_with_timeout(60)
    return code.to_i, msg
  end

  # Now we're ready to set the content type and return the contents in streaming fashion.
  def copyTo(out)
    begin
      while true
        data = @queue.pop_with_timeout(10)
        data.nil? and break
        out.write(data)
      end
    rescue Exception => e
      puts "Warning: problem while streaming content: #{e.message}"
    end
  end
end

###################################################################################################
get %r{/assets/([0-9a-f]{64})} do |hash|
  s3Path = "#{$s3Config.prefix}/binaries/#{hash[0,2]}/#{hash[2,2]}/#{hash}"
  obj = $s3Bucket.object(s3Path)
  obj.exists? && obj.metadata["mime_type"] or halt(404)
  content_type obj.metadata["mime_type"]
  response.headers['Content-Length'] = obj.content_length.to_s
  return stream { |out| obj.get(response_target: out) }
end

###################################################################################################
get "/content/:fullItemID/*" do |fullItemID, path|
  # Prep work
  fullItemID =~ /^qt[a-z0-9]{8}$/ or halt(404)  # protect against attacks
  item = Item[fullItemID]
  item.status == 'published' or halt(403)  # prevent access to embargoed and withdrawn files
  path = sanitizeFilePath(path)  # protect against attacks

  # Fetch the file from Merritt
  fetcher = Fetcher.new
  epath = URI::encode(path)
  code, msg = fetcher.start(URI("https://#{$mrtExpressConfig['host']}/dl/ark:/13030/#{fullItemID}/content/#{epath}"))
  code == 401 and raise("Error: mrtExpress credentials not recognized - check config/mrtExpress.yaml")

  # Temporary fallback: if we can't find on Merritt, try the raw_data hack on pub-eschol-stg.
  # This is needed for ETDs, since we don't yet record their proper original Merritt location.
  if code != 200
    fetcher = Fetcher.new
    code2, msg2 = fetcher.start(URI("https://pub-eschol-stg.escholarship.org/raw_data/13030/pairtree_root/" +
                                    "#{fullItemID.scan(/../).join('/')}/#{fullItemID}/content/#{epath}"))
    code2 == 200 or halt(code, msg)
  end

  # Guess the content type by path for now, and stream the results (don't buffer the whole thing,
  # as some files are huge and would blow out our RAM).
  content_type MimeMagic.by_path(path)
  return stream { |out| fetcher.copyTo(out) }
end

###################################################################################################
# If a cache buster comes in, strip it down to the original, and re-dispatch the request to return
# the actual file.
get %r{\/css\/main-[a-zA-Z0-9]{16}\.css} do
  call env.merge("PATH_INFO" => "/css/main.css")
end

###################################################################################################
# The outer framework of every page is essentially the same, substituting in the intial page
# data and initial elements from React.
get %r{.*} do

  # The regex below ensures that /api, /content, /locale, and files with a file ext get served
  # elsewhere.
  pass if request.path_info =~ %r{api/.*|content/.*|locale/.*|.*\.\w{1,4}}

  puts "Page fetch: #{request.url}"

  template = File.new("app/app.html").read

  # Replace startup URLs for proper cache busting
  # TODO: speed this up by caching (if it's too slow)
  webpackManifest = JSON.parse(File.read('app/js/manifest.json'))
  template.sub!("lib-bundle.js", webpackManifest["lib.js"])
  template.sub!("app-bundle.js", webpackManifest["app.js"])
  template.sub!("main.css", "main-#{Digest::MD5.file("app/css/main.css").hexdigest[0,16]}.css")

  if DO_ISO
    # We need to grab the hostname from the URL. There's probably a better way to do this.
    request.url =~ %r{^https?://([^/:]+)(:\d+)?(.*)$} or fail
    host = $1
    remainder = $3

    # Pass the full path and query string to our little Node Express app, which will run it through
    # ReactRouter and React.
    response = Net::HTTP.new(host, 4002).start {|http| http.request(Net::HTTP::Get.new(remainder)) }
    response.code == "200" or halt(500, "ISO fetch failed")

    # Read in the template file, and substitute the results from React/ReactRouter
    lookFor = '<div id="main"></div>'
    template.include?(lookFor) or raise("can't find #{lookFor.inspect} in template")
    return template.sub(lookFor, response.body)
  else
    # Development mode - skip iso
    return template
  end
end

###################################################################################################
# Pages with no data
get %r{/api/(home|notFound|logoutSuccess)} do
  content_type :json
  return { :header => getGlobalHeader }.to_json
end

###################################################################################################
# Browse all campuses
get "/api/browse/campuses" do 
  content_type :json
  # Build array of hashes containing campus and stats
  stats = []
  $activeCampuses.each do |k, v|
    pub_count =     ($statsCampusPubs.keys.include? k)  ? $statsCampusPubs[k]     : 0
    unit_count =    ($statsCampusOrus.keys.include? k)  ? $statsCampusOrus[k]     : 0
    journal_count = ($statsCampusJournals.keys.include? k) ? $statsCampusJournals[k] : 0
    stats.push({"id"=>k, "name"=>v.values[:name], "type"=>v.values[:type], 
      "publications"=>pub_count, "units"=>unit_count, "journals"=>journal_count})
  end
  body = {
    :header => getGlobalHeader,
    :browse_type => "campuses",
    :campusesStats => stats.select { |h| h['type']=="campus" },
    :affiliatedStats => stats.select { |h| h['type']=="oru" }
  }
  breadcrumb = [{"name" => "Campuses and Affiliated Units", "url" => "/campuses"},]
  return body.merge(getHeaderElements(breadcrumb, nil)).to_json
end

###################################################################################################
# Browse all journals
get "/api/browse/journals" do 
  content_type :json
  journals = $campusJournals.sort_by{ |h| h[:name].downcase }
  body = {
    :header => getGlobalHeader,
    :browse_type => "all_journals",
    :journals => journals.select{ |h| h[:status]!="archived" },
    :archived => journals.select{ |h| h[:status]=="archived" }
  }
  breadcrumb = [{"name" => "Journals", "url" => "/journals"},]
  return body.merge(getHeaderElements(breadcrumb, "All Campuses")).to_json
end

###################################################################################################
# Browse a campus's units or journals
get "/api/browse/:browse_type/:campusID" do |browse_type, campusID|
  content_type :json
  cu, cj, pageTitle = nil, nil, nil
  if browse_type == 'units'
    cu = $hierByAncestor[campusID].map do |a| getChildDepts($unitsHash[a.unit_id]); end
    pageTitle = "Academic Units"
  else   # journals
    cj  = $campusJournals.select{ |j| j[:ancestor_unit].include?(campusID) }.sort_by{ |h| h[:name].downcase }
    cja = cj.select{ |h| h[:status]=="archived" }
    cj  = cj.select{ |h| h[:status]!="archived" }
    pageTitle = "Journals"
  end
  unit = $unitsHash[campusID]
  attrs = JSON.parse(unit[:attrs])
  body = {
    :browse_type => browse_type,
    :pageTitle => pageTitle,
    :unit => unit ? unit.values.reject { |k,v| k==:attrs } : nil,
    :header => unit ? getUnitHeader(unit, nil, attrs) : getGlobalHeader,
    :campusUnits => cu ? cu.compact : nil,
    :campusJournals => cj,
    :campusJournalsArchived => cja
  }
  breadcrumb = [
    {"name" => pageTitle, "url" => "/" + campusID + "/" + browse_type},
    {"name" => unit.name, "url" => "/uc/" + campusID}]
  return body.merge(getHeaderElements(breadcrumb, nil)).to_json
end

def getChildDepts(unit)
  if unit.type != 'oru'
    return nil
  else
    node = {"id" => unit.id, "name" => unit.name}
    child = $hierByAncestor[unit.id].map { |c| getChildDepts($unitsHash[c.unit_id]) }.compact
    if child[0] then node["children"] = child end
    return node
  end
end


###################################################################################################
# Unit page data.
get "/api/unit/:unitID/:pageName/?:subPage?" do
  content_type :json
  unit = Unit[params[:unitID]]
  unit or halt(404, "Unit not found")

  attrs = JSON.parse(unit[:attrs])
  pageName = params[:pageName]
  if pageName
    ext = nil
    begin
      ext = extent(unit.id, unit.type)
    rescue Exception => e
      halt 404, "Error building page data:" + e.message
    end
    pageData = {
      unit: unit.values.reject{|k,v| k==:attrs}.merge(:extent => ext),
      header: getUnitHeader(unit, pageName =~ /^(nav|sidebar)/ ? nil : pageName, attrs),
      sidebar: getUnitSidebar(unit)
    }
    if ["home", "search"].include? pageName
      q = nil
      q = CGI::parse(request.query_string) if pageName == "search"
      pageData[:content] = getUnitPageContent(unit, attrs, q)
    # This is subsumed under getUnitPageContent right now
    # elsif pageName == 'search'
    #   pageData[:content] = unitSearch(CGI::parse(request.query_string), unit)
    elsif pageName == 'profile'
      pageData[:content] = getUnitProfile(unit, attrs)
    elsif pageName == 'nav'
      pageData[:content] = getUnitNavConfig(unit, attrs['nav_bar'], params[:subPage])
    elsif pageName == 'sidebar'
      pageData[:content] = getUnitSidebarWidget(unit, params[:subPage])
    else
      pageData[:content] = getUnitStaticPage(unit, attrs, pageName)
    end
    pageData[:marquee] = getUnitMarquee(unit, attrs) if ["home", "search"].include? pageName
  else
    #public API data
    pageData = {
      unit: unit.values.reject{|k,v| k==:attrs}
    }
  end
  #print "pageData="; pp pageData
  return pageData.to_json
end

###################################################################################################
# Item view page data.
get "/api/item/:shortArk" do |shortArk|
  content_type :json
  id = "qt"+shortArk
  item = Item[id]
  attrs = JSON.parse(Item.filter(:id => id).map(:attrs)[0])
  unitIDs = UnitItem.where(:item_id => id, :is_direct => true).order(:ordering_of_units).select_map(:unit_id)
  unit = unitIDs ? Unit[unitIDs[0]] : nil

  if !item.nil?
    authors = ItemAuthors.filter(:item_id => id).order(:ordering).
                 map(:attrs).collect{ |h| JSON.parse(h)}
    citation = getCitation(shortArk, authors, attrs)
    begin
      body = {
        :id => shortArk,
        :citation => citation,
        :title => citation[:title],
        # ToDo: Normalize author attributes across all components (i.e. 'family' vs. 'lname')
        :authors => authors,
        :pub_date => item.pub_date,
        :status => item.status,
        :rights => item.rights,
        :content_type => item.content_type,
        :content_html => getItemHtml(item.content_type, shortArk),
        :attrs => attrs,
        :appearsIn => unitIDs ? unitIDs.map { |unitID| {"id" => unitID, "name" => Unit[unitID].name} }
                              : nil,
        :header => unit ? getUnitHeader(unit) : nil,
        :unit => unit ? unit.values.reject { |k,v| k==:attrs } : nil
      }

      # TODO: at some point we'll want to modify the breadcrumb code to include CMS pages and issues
      # in a better way - I don't think this belongs here in the item-level code.
      # Unit type dependency also affects citation
      if unit && unit.type == 'journal'
        issue_id = Item.join(:sections, :id => :section).filter(:items__id => id).map(:issue_id)[0]
        volume, issue = Section.join(:issues, :id => issue_id).map([:volume, :issue])[0]
        body[:header][:breadcrumb] << {name: "Volume #{volume}, Issue #{issue}",
          url: "/uc/#{unitIDs[0]}/#{volume}/#{issue}"}
        body[:citation][:volume] = volume
        body[:citation][:issue] = issue
      end

      return body.to_json
    rescue Exception => e
      puts "Error in item API:"
      pp e
      halt 404, e.message
    end
  else 
    puts "Item not found!"
    halt 404, "Item not found"
  end
end

###################################################################################################
# Search page data
get "/api/search/" do
  content_type :json
  body = {
    :header => getGlobalHeader,
    :campuses => getCampusesAsMenu
  }
  facetList = ['type_of_work', 'peer_reviewed', 'supp_file_types', 'pub_year',
               'campuses', 'departments', 'journals', 'disciplines', 'rights']
  params = CGI::parse(request.query_string)
  searchType = params["searchType"][0]
  # Perform global search when searchType is assigned 'eScholarship'
  # otherwise: 'searchType' will be assigned the unit ID - and then 'searchUnitType' specifies type of unit.
  if searchType and searchType != "eScholarship"
    searchUnitType = params["searchUnitType"][0]
    if searchUnitType.nil? or searchUnitType == ''
      params["searchType"] = ["eScholarship"]
    else
      params[searchUnitType] = [searchType]
    end
  end
  return body.merge(search(params, facetList)).to_json
end

###################################################################################################
# Social Media Links  for type = (item|unit)
get "/api/mediaLink/:type/:id/:service" do |type, id, service| # service e.g. facebook, google, etc.
  content_type :json
  sharedLink = "http://www.escholarship.org/" + type + "/" + id 
  item = ''
  if (type == "item")
    item = Item["qt"+id]
    title = item.title
  else
    title = $unitsHash[id].name
  end
  case service
    when "facebook"
      url = "http://www.facebook.com/sharer.php?u=" + sharedLink
    when "twitter"
      url = "http://twitter.com/home?status=" + title + "[" + sharedLink + "]"
    when "email"
      title_sm = title.length > 50 ? title[0..49] + "..." : title
      body = ''
      if (type == "item")
        # ToDo: Put in proper citation
        body = (item.attrs["orig_citation"] ? item.attrs["orig_citation"] + "\n\n" : "")
      else
        body = "View items by " + title + " published on eScholarship.\n\n" 
      end
      url = ("mailto:?subject=" + title_sm + "&body=%s" + sharedLink) % [body]
    when "mendeley"
      url = "http://www.mendeley.com/import?url=" + sharedLink + "&title=" + title
    when "citeulike"
      url = "http://www.citeulike.org/posturl?url=" + sharedLink + "&title=" + title
    else
      raise("unrecognized service")
  end
  return { url: url }.to_json
end

##################################################################################################
# Helper methods

def getGlobalHeader
    return {
   nav_bar: [
     { id: 1, name: "About", sub_nav: [ { name: "TBD", url: "#" } ] },
     { id: 2, name: "Campus Sites",
       sub_nav: $activeCampuses.map { |k, v| { name: v.values[:name], url: "/uc/#{k}" } }
     },
     { id: 3, name: "UC Open Access", sub_nav: [ { name: "TBD", url: "#" } ] },
     { id: 4, name: "eScholarship Publishing", url: "#" },
   ]
    # was: JSON.parse($unitsHash['root'][:attrs])['nav_bar']
  }
end

# Generate breadcrumb and header content for Browse or Static page
def getHeaderElements(breadcrumb, topItem)
  campuses = topItem ? getCampusesAsMenu(topItem) : getCampusesAsMenu
  return {
    :campuses => campuses,
    :breadcrumb => breadcrumb ? Hierarchy_Manual.new(breadcrumb).generateCrumb : nil
  }
end

# Array of all active root level campuses/ORUs. Include empty label "eScholarship at..." 
def getCampusesAsMenu(topItem="eScholarship at...")
  campuses = []
  $activeCampuses.each do |id, c| campuses << {id: c.id, name: c.name} end
  return campuses.unshift({:id => "", :name=>topItem})
end

# Properly target links in HTML blob
def getItemHtml(content_type, id)
  return false if content_type != "text/html"
  dir = "http://" + request.env["HTTP_HOST"] + "/content/qt" + id + "/"
  htmlStr = open(dir + "qt" + id + ".html").read
  htmlStr.gsub(/(href|src)="((?!#)[^"]+)"/) { |m|
    attrib, url = $1, $2
    url = $2.start_with?("http", "ftp") ? $2 : dir + $2
    "#{attrib}=\"#{url}\"" + ((attrib == "src") ? "" : " target=\"new\"")
  }
end

###################################################################################################
# Static page data.
get "/api/static/:unitID/:pageName" do |unitID, pageName|
  content_type :json

  # Grab unit and page data from the database, not the cache, so they are instantly updated
  # when adding a page.
  unit = Unit[unitID]
  unit or halt(404, "Unit not found")

  page = Page.where(unit_id: unitID, name: pageName).first
  page or halt(404, "Page not found")

  body = {
    header: unitID=='root' ? getGlobalHeader : getUnitHeader(unit),
    campuses: getCampusesAsMenu,
    page: {
      title: page.title,
      html: JSON.parse(page.attrs)['html']
    },
    sidebarWidgets: Widget.where(unit_id: unitID, region: 'sidebar').order(:ordering).map { |w|
      attrs = w.attrs ? JSON.parse(w.attrs) : {}
      { id: w.id,
        kind: w.kind,
        title: attrs['title'] ? attrs['title'] : w.kind,
        html: attrs['html'] ? attrs['html'] :
                "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Labore, saepe fugiat nihil molestias quam fugit harum suscipit, soluta debitis praesentium. Minus repudiandae debitis non dolore dignissimos, aliquam corporis ratione, quasi." }
    },
    sidebarNavLinks: [{"name" => "About eScholarship", "url" => request.path.sub("/api/", "/")},]
  }
  breadcrumb = [{"name" => "About eScholarship", "url" => request.path.sub("/api/", "/")},]
  return body.merge(getHeaderElements(breadcrumb, nil)).to_json
end

###################################################################################################
# The first line of defense against unwanted or unsafe HTML is the WYSIWIG editor's built-in
# filtering. However, since this is an API we cannot rely on that. This is the second line of
# defense.
def sanitizeHTML(htmlFragment)
  return Sanitize.fragment(htmlFragment,
    elements: %w{b em i strong u} +                      # all 'restricted' tags
              %w{a br li ol p small strike sub sup ul hr},  # subset of ''basic' tags
    attributes: { "a" => ['href'] },
    protocols:  { "a" => {'href' => ['ftp', 'http', 'https', 'mailto', :relative]} }
  )
end

###################################################################################################
# Post from github notifying us of a push to the repo
post "/jscholGithubHook/onCommit" do
  puts "Got github commit hook - doing pull and restart."
  pid = spawn("/usr/bin/ruby tools/pullJschol.rb > /apps/eschol/tmp/pullJschol.log 2>&1")
  Process.detach(pid)
  return "ok"
end
