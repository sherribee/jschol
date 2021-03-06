def traverseHierarchyUp(arr)
  if ['root', nil].include? arr[0][:id]
    return arr
  end
  unit = $unitsHash[$hierByUnit[arr[0][:id]][0].ancestor_unit]
  traverseHierarchyUp(arr.unshift({name: unit.name, id: unit.id, url: "/uc/" + unit.id}))
end

# Generate a link to an image in the S3 bucket
def getLogoData(data)
  data && data['asset_id'] && data['width'] && data['height'] or return nil
  return { url: "/assets/#{data['asset_id']}", width: data['width'], height: data['height'] }
end

# Add a URL to each nav bar item
def getNavBar(unitID, pageName, navItems)
  if navItems
    navItems.each { |navItem|
      if navItem['slug']
        navItem['url'] = "/uc/#{unitID}#{navItem['slug']=="" ? "" : "/"+navItem['slug']}"
      end
    }
    navItems.unshift({ id: 0, type: "home", name: "Unit Home", url: "/uc/#{unitID}" })
    return navItems
  end
  return nil
end

# Generate the last part of the breadcrumb for a static page within a unit
def getPageBreadcrumb(unit, pageName)
  (!pageName || pageName == "home" || pageName == "campus_landing") and return []
  pageName == "search" and return [{ name: "Search", id: unit.id + ":" + pageName}]
  pageName == "profile" and return [{ name: "Profile", id: unit.id + ":" + pageName}]
  pageName == "sidebar" and return [{ name: "Sidebars", id: unit.id + ":" + pageName}]
  p = Page.where(unit_id: unit.id, slug: pageName).first
  p or halt(404, "Unknown page #{pageName} in #{unit.id}")
  return [{ name: p[:name], id: unit.id + ":" + pageName, url: "/#{unit.id}/#{pageName}" }]
end

# Generate breadcrumb and header content for Unit-branded pages
def getUnitHeader(unit, pageName=nil, attrs=nil)
  if !attrs then attrs = JSON.parse(unit[:attrs]) end
  r = UnitHier.where(unit_id: unit.id).where(ancestor_unit: $activeCampuses.keys).first
  campusID = (unit.type=='campus') ? unit.id : r ? r.ancestor_unit : 'root'
  header = {
    :campusID => campusID,
    :campusName => $unitsHash[campusID].name,
    :campuses => $activeCampuses.values.map { |c| {id: c.id, name: c.name} }.unshift({id: "", name: "eScholarship at..."}),
    :logo => getLogoData(attrs['logo']),
    :nav_bar => getNavBar(unit.id, pageName, attrs['nav_bar']),
    :social => {
      :facebook => attrs['facebook'],
      :twitter => attrs['twitter'],
      :rss => attrs['rss']
    },
    :breadcrumb => (unit.type!='campus') ?
      traverseHierarchyUp([{name: unit.name, id: unit.id, url: "/uc/" + unit.id}]) + getPageBreadcrumb(unit, pageName)
      : getPageBreadcrumb(unit, pageName)
  }

  # if this unit doesn't have a nav_bar, get the next unit up the hierarchy's nav_bar
  if !header[:nav_bar] and unit.type != 'campus'
    ancestor = $hierByUnit[unit.id][0].ancestor
    until header[:nav_bar] || ancestor.id == 'root'
      header[:nav_bar] = JSON.parse(ancestor[:attrs])['nav_bar']
      ancestor = $hierByUnit[ancestor.id][0].ancestor
    end
  end

  return header
end

def getUnitPageContent(unit, attrs, q)
  if unit.type == 'oru'
   return getORULandingPageData(unit.id)
  elsif unit.type == 'campus'
    return getCampusLandingPageData(unit, attrs)
  elsif unit.type.include? 'series'
    return getSeriesLandingPageData(unit, q)
  elsif unit.type == 'journal'
    return getJournalLandingPageData(unit.id)
  else
    # ToDo: handle 'special' type here
    halt(404, "Unknown unit type #{unit.type}")
  end
end

def getUnitMarquee(unit, attrs)
  return {
    :about => attrs['about'],
    :carousel => attrs['carousel']
  }
end

# Get ORU-specific data for Department Landing Page
def getORULandingPageData(id)
  # addPage()
  children = $hierByAncestor[id]

  return {
    :series => children ? children.select { |u| u.unit.type == 'series' }.map { |u| seriesPreview(u) } : [],
    :journals => children ? children.select { |u| u.unit.type == 'journal' }.map { |u| {unit_id: u.unit_id, name: u.unit.name} } : [],
    :related_orus => children ? children.select { |u| u.unit.type != 'series' && u.unit.type != 'journal' }.map { |u| {unit_id: u.unit_id, name: u.unit.name} } : []
  }
end

# Get data for Campus Landing Page
def getCampusLandingPageData(unit, attrs)
  return {
    :pub_count =>     ($statsCampusPubs.keys.include? unit.id)  ? $statsCampusPubs[unit.id]     : 0,
    :view_count =>    0,
    :opened_count =>    0,
    :journal_count => ($statsCampusJournals.keys.include? unit.id) ? $statsCampusJournals[unit.id] : 0,
    :unit_count =>    ($statsCampusOrus.keys.include? unit.id)  ? $statsCampusOrus[unit.id]     : 0
  }
end

# Preview of Series for a Department Landing Page
def seriesPreview(u)
  items = UnitItem.filter(:unit_id => u.unit_id, :is_direct => true)
  count = items.count
  preview = items.limit(3).map(:item_id)
  itemData = readItemData(preview)

  {
    :unit_id => u.unit_id,
    :name => u.unit.name,
    :count => count,
    :items => itemResultData(preview, itemData)
  }
end

def getSeriesLandingPageData(unit, q)
  parent = $hierByUnit[unit.id]
  if parent.length > 1
    pp parent
  else
    children = parent ? $hierByAncestor[parent[0].ancestor_unit] : []
  end

  response = unitSearch(q ? q : {"sort" => ['desc']}, unit)
  response[:series] = children ? children.select { |u| u.unit.type == 'series' }.map { |u| {unit_id: u.unit_id, name: u.unit.name} } : []
  return response
end

def getJournalLandingPageData(id)
  unit = $unitsHash[id]
  attrs = JSON.parse(unit.attrs)
  return {
    display: attrs['splashy'] ? 'splashy' : 'simple',
    issue: getIssue(id)
  }
end

def getIssue(id)
  issue1 = Issue.where(:unit_id => id).order(Sequel.desc(:pub_date)).first
  return nil if issue1.nil?
  issue = issue1.values
  issue[:sections] = Section.where(:issue_id => issue[:id]).order(:ordering).all

  issue[:sections].map! do |section|
    section = section.values
    items = Item.where(:section=>section[:id]).order(:ordering_in_sect).to_hash(:id)
    itemIds = items.keys
    authors = ItemAuthors.where(item_id: itemIds).order(:ordering).to_hash_groups(:item_id)

    itemData = {items: items, authors: authors}

    section[:articles] = itemResultData(itemIds, itemData)

    next section
  end
  return issue
end



def unitSearch(params, unit)
  # ToDo: Right now, series landing page is the only unit type using this block. Clean this up
  # once a final decision has been made about display of different unit search pages
  if unit.type.include? 'series'
    resultsListFields = ['thumbnail', 'pub_year', 'publication_information', 'type_of_work', 'rights']
    params["series"] = [unit.id]
  elsif unit.type == 'oru'
    resultsListFields = ['thumbnail', 'pub_year', 'publication_information', 'type_of_work']
    params["departments"] = [unit.id]
  elsif unit.type == 'journal'
    resultsListFields = ['thumbnail', 'pub_year', 'publication_information']
    params["journals"] = [unit.id]
  elsif unit.type == 'campus'
    resultsListFields = ['thumbnail', 'pub_year', 'publication_information', 'type_of_work', 'rights', 'peer_reviewed']
    params["campuses"] = [unit.id]
  else
    #throw 404
    pp unit.type
  end

  aws_params = aws_encode(params, [])
  response = normalizeResponse($csClient.search(return: '_no_fields', **aws_params))

  if response['hits'] && response['hits']['hit']
    itemIds = response['hits']['hit'].map { |item| item['id'] }
    itemData = readItemData(itemIds)
    searchResults = itemResultData(itemIds, itemData, resultsListFields)
  end

  return {'count' => response['hits']['found'], 'query' => get_query_display(params.clone), 'searchResults' => searchResults}
end

def getUnitStaticPage(unit, attrs, pageName)
  page = Page[:slug=>pageName, :unit_id=>unit.id].values
  page[:attrs] = JSON.parse(page[:attrs])
  return page
end

def getUnitProfile(unit, attrs)
  profile = {
    name: unit.name,
    slug: unit.id,
    logo: attrs['logo'],
    facebook: attrs['facebook'],
    twitter: attrs['twitter'],
    carousel: attrs['carousel'],
    about: attrs['about']
  }
  if unit.type == 'journal'
    profile[:doaj] = attrs['doaj']
    profile[:license] = attrs['license']
    profile[:eissn] = attrs['eissn']
    profile[:splashy] = attrs['splashy']
    profile[:issue_rule] = attrs['issue_rule']
  end
  if unit.type == 'oru'
    profile[:seriesSelector] = true
  end
  return profile
end

def getItemAuthors(itemID)
  return ItemAuthors.filter(:item_id => itemID).order(:ordering).map(:attrs).collect{ |h| JSON.parse(h)}
end

# Get recent items (with author info) for a unit, by most recent eschol_date
def getRecentItems(unit)
  items = Item.join(:unit_items, :item_id => :id).where(unit_id: unit.id)
              .where(Sequel.lit("attrs->\"$.suppress_content\" is null"))
              .reverse(:eschol_date).limit(5)
  return items.map { |item|
    { id: item.id, title: item.title, authors: getItemAuthors(item.id) }
  }
end

def getUnitSidebar(unit)
  return Widget.where(unit_id: unit.id, region: "sidebar").order(:ordering).map { |widget|
    attrs =  widget[:attrs] ? JSON.parse(widget[:attrs]) : {}
    widget[:kind] == "RecentArticles" and attrs[:items] = getRecentItems(unit)
    next { id: widget[:id], kind: widget[:kind], attrs: attrs }
  }
end

def getUnitSidebarWidget(unit, widgetID)
  widget = Widget[widgetID]
  widget.unit_id == unit.id && widget.region == "sidebar" or jsonHalt(400, "invalid widget")
  return { id: widget[:id], kind: widget[:kind], attrs: widget[:attrs] ? JSON.parse(widget[:attrs]) : {} }
end

# Traverse the nav bar, including sub-folders, yielding each item in turn
# to the supplied block.
def travNav(navBar, &block)
  navBar.each { |nav|
    block.yield(nav)
    if nav['type'] == 'folder'
      travNav(nav['sub_nav'], &block)
    end
  }
end

def getNavByID(navBar, navID)
  travNav(navBar) { |nav|
    nav['id'].to_s == navID.to_s and return nav
  }
  return nil
end

def deleteNavByID(navBar, navID)
  return navBar.map { |nav|
    nav['id'].to_s == navID.to_s ? nil
      : nav['type'] == "folder" ? nav.merge({'sub_nav'=>deleteNavByID(nav['sub_nav'], navID) })
      : nav
  }.compact
end

def getUnitNavConfig(unit, navBar, navID)
  travNav(navBar) { |nav|
    if nav['id'].to_s == navID.to_s
      if nav['type'] == 'page'
        page = Page.where(unit_id: unit.id, slug: nav['slug']).first
        page or halt(404, "Unknown page #{nav['slug']} for unit #{unit.id}")
        nav['title'] = page.title
        nav['attrs'] = JSON.parse(page.attrs)
      end
      return nav
    end
  }
  halt(404, "Unknown nav #{navID} for unit #{unit.id}")
end

###################################################################################################
def maxNavID(navBar)
  n = 0
  travNav(navBar) { |nav| n = [n, nav["id"]].max }
  return n
end

def jsonHalt(httpCode, message)
  content_type :json
  halt(httpCode, { error: true, message: message }.to_json)
end

put "/api/unit/:unitID/nav/:navID" do |unitID, navID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)
  content_type :json

  DB.transaction {
    unit = Unit[unitID] or jsonHalt(404, "Unit not found")
    unitAttrs = JSON.parse(unit.attrs)
    params[:name].empty? and jsonHalt(400, "Page name must be supplied.")

    travNav(unitAttrs['nav_bar']) { |nav|
      next unless nav['id'].to_s == navID.to_s
      nav['name'] = params[:name]
      if nav['type'] == "page"
        page = Page.where(unit_id: unitID, slug: nav['slug']).first or halt(404, "Page not found")

        oldSlug = page.slug
        newSlug = params[:slug]
        newSlug.empty? and jsonHalt(400, "Slug must be supplied.")
        newSlug =~ /^[a-zA-Z][a-zA-Z0-9_]+$/ or jsonHalt(400,
          message: "Slug must start with a letter a-z, and consist only of letters a-z, numbers, or underscores.")
        page.slug = newSlug
        nav['slug'] = newSlug

        page.name = params[:name]
        page.name.empty? and jsonHalt(400, "Page name must be supplied.")

        page.title = params[:title]
        page.title.empty? and jsonHalt(400, "Title must be supplied.")

        newHTML = sanitizeHTML(params[:attrs][:html])
        newHTML.empty? and jsonHalt(400, "Text must be supplied.")
        page.attrs = JSON.parse(page.attrs).merge({ "html" => newHTML }).to_json
        page.save
      elsif nav['type'] == "link"
        params[:url] =~ %r{^https?://.*} or jsonHalt(400, "Invalid URL.")
        nav['url'] = params[:url]
      end
      unit.attrs = unitAttrs.to_json
      unit.save
      return {status: "ok"}.to_json
    }
    jsonHalt(404, "Unknown nav #{navID} for unit #{unitID}")
  }
end

def remapOrder(oldNav, newOrder)
  newOrder = newOrder.map { |stub| stub['id'] == 0 ? nil : stub }.compact
  return newOrder.map { |stub|
    source = getNavByID(oldNav, stub['id'])
    source or raise("Unknown nav id #{stub['id']}")
    newNav = source.clone
    if source['type'] == "folder"
      stub['sub_nav'] or raise("can't change nav type")
      newNav['sub_nav'] = remapOrder(oldNav, stub['sub_nav'])
    end
    next newNav
  }
end

###################################################################################################
# *Put* to change the ordering of nav bar items
put "/api/unit/:unitID/navOrder" do |unitID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)
  content_type :json

  DB.transaction {
    unit = Unit[unitID] or halt(404, "Unit not found")
    unitAttrs = JSON.parse(unit.attrs)
    newOrder = JSON.parse(params[:order])
    newOrder.empty? and jsonHalt(400, "Page name must be supplied.")
    newNav = remapOrder(unitAttrs['nav_bar'], newOrder)
    unitAttrs['nav_bar'] = newNav
    unit.attrs = unitAttrs.to_json
    unit.save
    return {status: "ok"}.to_json
  }
end

###################################################################################################
# *Post* to add an item to a nav bar
post "/api/unit/:unitID/nav" do |unitID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  # Grab unit data
  unit = Unit[unitID]
  unit or halt(404)

  # Validate the nav type
  navType = params[:navType]
  ['page', 'link', 'folder'].include?(navType) or halt(400)

  # Find the existing nav bar
  attrs = JSON.parse(unit.attrs)
  (navBar = attrs['nav_bar']) or raise("Unit has non-existent nav bar")

  # Invent a unique name for the new item
  slug = name = nil
  (1..9999).each { |n|
    slug = "#{navType}#{n.to_s}"
    name = "New #{navType} #{n.to_s}"
    break if navBar.none? { |nav| nav['slug'] == slug || nav['name'] == name }
  }

  nextID = maxNavID(navBar) + 1

  DB.transaction {
    newNav = case navType
    when "page"
      Page.create(slug: slug, unit_id: unitID, name: name, title: name, attrs: { html: "" }.to_json)
      newNav = { id: nextID, type: "page", name: name, slug: slug, hidden: true }
    when "link"
      newNav = { id: nextID, type: "link", name: name, url: "" }
    when "folder"
      newNav = { id: nextID, type: "folder", name: name, sub_nav: [] }
    else
      halt(400, "unknown navType")
    end

    navBar << newNav
    attrs['nav_bar'] = navBar
    unit[:attrs] = attrs.to_json
    unit.save

    return { status: "ok", nextURL: "/uc/#{unitID}/nav/#{newNav[:id]}" }.to_json
  }
end

###################################################################################################
# *Post* to add a widget to the sidebar
post "/api/unit/:unitID/sidebar" do |unitID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or jsonHalt(401, "unauthorized")

  # Grab unit data
  unit = Unit[unitID]
  unit or jsonHalt(404, "unknown unit")

  # Validate the widget kind
  widgetKind = params[:widgetKind]
  ['RecentArticles', 'Text', 'Tweets'].include?(widgetKind) or jsonHalt(400, "Invalid widget kind")

  # Initial attributes are kind-specific
  attrs = case widgetKind
  when "Text"
    { title: "New #{widgetKind}", html: "" }
  else
    {}
  end

  # Determine an ordering that will place this last.
  lastOrder = Widget.where(unit_id: unitID).max(:ordering)
  order = (lastOrder || 0) + 1

  # Okay, create it.
  newID = Widget.create(unit_id: unitID, kind: widgetKind,
                        ordering: order, attrs: attrs.to_json, region: "sidebar").id
  return { status: "ok", nextURL: "/uc/#{unitID}/sidebar/#{newID}" }.to_json
end

###################################################################################################
# *Put* to change the ordering of sidebar widgets
put "/api/unit/:unitID/sidebarOrder" do |unitID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)
  content_type :json

  DB.transaction {
    unit = Unit[unitID] or jsonHalt(404, "Unit not found")
    newOrder = JSON.parse(params[:order])
    Widget.where(unit_id: unitID).count == newOrder.length or jsonHalt(400, "must reorder all at once")

    # Make two passes, to absolutely avoid conflicting order in the table at any time.
    maxOldOrder = Widget.where(unit_id: unitID).max(:ordering)
    (1..2).each { |pass|
      offset = (pass == 1) ? maxOldOrder+1 : 1
      newOrder.each_with_index { |widgetID, idx|
        w = Widget[widgetID]
        w.unit_id == unitID or jsonHalt(400, "widget/unit mistmatch")
        w.ordering = idx + offset
        w.save
      }
    }
  }

  return {status: "ok"}.to_json
end

###################################################################################################
# *Delete* to remove sidebar widget
delete "/api/unit/:unitID/sidebar/:widgetID" do |unitID, widgetID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  DB.transaction {
    unit = Unit[unitID] or halt(404, "Unit not found")
    widget = Widget[widgetID]
    widget.unit_id == unitID and widget.region == "sidebar" or jsonHalt(400, "invalid widget")
    widget.delete
  }

  content_type :json
  return {status: "ok", nextURL: "/uc/#{unitID}" }.to_json
end

###################################################################################################
# *Delete* to remove a static page from a unit
delete "/api/unit/:unitID/nav/:navID" do |unitID, navID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  DB.transaction {
    unit = Unit[unitID] or halt(404, "Unit not found")
    unitAttrs = JSON.parse(unit.attrs)
    nav = getNavByID(unitAttrs['nav_bar'], navID)
    unitAttrs['nav_bar'] = deleteNavByID(unitAttrs['nav_bar'], navID)
    getNavByID(unitAttrs['nav_bar'], navID).nil? or raise("delete failed")
    if nav['type'] == "folder" && !nav['sub_nav'].empty?
      jsonHalt(404, "Can't delete non-empty folder")
    end
    if nav['type'] == "page"
      page = Page.where(unit_id: unitID, slug: nav['slug']).first or jsonHalt(404, "Page not found")
      page.delete
    end

    unit.attrs = unitAttrs.to_json
    unit.save
  }

  content_type :json
  return {status: "ok", nextURL: "/uc/#{unitID}" }.to_json
end

###################################################################################################
# *Put* to change the attributes of a sidebar widget
put "/api/unit/:unitID/sidebar/:widgetID" do |unitID, widgetID|

  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  DB.transaction {
    unit = Unit[unitID] or halt(404, "Unit not found")
    widget = Widget[widgetID]
    widget.attrs = params[:attrs].to_json
    widget.save
  }

  # And let the caller know it went fine.
  content_type :json
  return { status: "ok" }.to_json
end

###################################################################################################
# *Put* to change the main text on a static page
put "/api/static/:unitID/:pageName/mainText" do |unitID, pageName|

  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  # Grab page data from the database
  page = Page.where(unit_id: unitID, slug: pageName).first or halt(404, "Page not found")

  # Parse the HTML text, and sanitize to be sure only allowed tags are used.
  safeText = sanitizeHTML(params[:newText])

  # Update the database
  page.attrs = JSON.parse(page.attrs).merge({ "html" => safeText }).to_json
  page.save

  # And let the caller know it went fine.
  content_type :json
  return { status: "ok" }.to_json
end

###################################################################################################
# *Put* to change unit profile properties: content configuration
put "/api/unit/:unitID/profileContentConfig" do |unitID|
  # Check user permissions
  perms = getUserPermissions(params[:username], params[:token], unitID)
  perms[:admin] or halt(401)

  DB.transaction {
    unit = Unit[unitID] or jsonHalt(404, "Unit not found")
    unitAttrs = JSON.parse(unit.attrs)

    if params['data']['splashy'] == "on"
      unitAttrs['splashy'] = true
    else
      unitAttrs.delete('splashy')
    end

    if params['data']['issue_rule'] == "secondMostRecent"
      unitAttrs['issue_rule'] = "secondMostRecent"
    else
      unitAttrs.delete('issue_rule')
    end

    unit.attrs = unitAttrs.to_json
    unit.save
  }

  content_type :json
  return { status: "ok" }.to_json
end
