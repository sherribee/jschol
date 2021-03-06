
import React from 'react'
import $ from 'jquery'
import _ from 'lodash'
import { Broadcast, Subscriber } from 'react-broadcast'

import SkipNavComp from '../components/SkipNavComp.jsx'
import Header1Comp from '../components/Header1Comp.jsx'
import FooterComp from '../components/FooterComp.jsx'
import DrawerComp from '../components/DrawerComp.jsx'
import TestMessageComp from '../components/TestMessageComp.jsx'

// Keys used to store CMS-related data in browser's session storage
const SESSION_LOGIN_KEY = "escholLogin"
const SESSION_EDITING_KEY = "escholEditingPage"

// Session storage is not available on server, only on browser
let sessionStorage = (typeof window != "undefined") ? window.sessionStorage : null

class PageBase extends React.Component
{
  getEmptyState() {
    return {
      pageData: null,
      isEditingPage: false,
      cmsModules: null
    }
  }

  // We initialize state here instead of in the constructor because, for some cases, it'll
  // result in starting an asynchronous fetch, and there would be a danger that fetch comes
  // back before the component is ready to receive state.
  componentWillMount() {
    let state = this.getEmptyState()
    let dataURL = this.pageDataURL(this.props)
    if (dataURL)
    {
      // Phase 1: Initial server-side load. We just save the URL, and iso will later fetch it and re-run React
      if (this.props.location.urlsToFetch) {
        state.fetchingData = true
        this.props.location.urlsToFetch.push(dataURL)
      }
      // Phase 2: Second server-side load, where our data has been fetched and stored in props.location
      else if (this.props.location.urlsFetched) {
        state.fetchingData = false
        state.pageData = this.props.location.urlsFetched[this.pageDataURL(this.props)]
      }
      // Phase 3: Initial browser load. Server should have placed our data in window.
      else if (window.jscholApp_initialPageData) {
        state.fetchingData = false
        state.pageData = window.jscholApp_initialPageData
        delete window.jscholApp_initialPageData
      }
      // Phase 4: Browser-side page switch. We have to fetch new data ourselves. Start with basic
      // state, and the pageData will get filled when the ajax returns.
      else {
        state.fetchingData = true
        this.fetchPageData(this.props)
      }
    }
    else
      state.pageData = {}

    // That's the final state.
    this.setState(state)
  }

  componentDidMount() {
    // Retrieve login info from session storage (but after initial init, so that ISO matches for first render)
    let d = this.getSessionData()
    if (d) {
      let newState = { adminLogin: { loggedIn: true, username: d.username, token: d.token },
                       isEditingPage: d.isEditingPage }
      this.setState(newState)
      this.fetchPermissions(newState)
    }
  }

  getSessionData() {
    return sessionStorage && JSON.parse(sessionStorage.getItem(SESSION_LOGIN_KEY))
  }

  setSessionData(data) {
    return sessionStorage && sessionStorage.setItem(SESSION_LOGIN_KEY, JSON.stringify(data))
  }

  onLogin = (username, token) => {
    if (!this.state.adminLogin || username != this.state.adminLogin.username || token != this.state.adminLogin.token)
    {
      this.setSessionData({ username: username, token: token })
      this.setState({ adminLogin: { loggedIn: true, username: username, token: token },
                      isEditingPage: false })
    }
  };

  onLogout = () => {
    this.setSessionData(null)
    this.setState({ adminLogin: { loggedIn: false } })
  };

  // Called when user clicks Edit Page, or Done Editing
  onEditingPageChange = flag => {
    this.setSessionData(Object.assign(this.getSessionData(), { isEditingPage: flag }))
    this.setState({ isEditingPage: flag })
  }

  // Pages with any editable components should override this.
  isPageEditable() {
    return false
  }

  // Browser-side AJAX fetch of page data. Sets state when the data is returned to us.
  fetchPageData = props => {
    this.dataURL = this.pageDataURL(props)
    if (this.dataURL) {
      this.setState({ fetchingData: true })
      $.getJSON(this.pageDataURL(props)).done((data) => {
        this.setState({ pageData: data, fetchingData: false })
      }).fail((jqxhr, textStatus, err)=> {
        this.setState({ pageData: null, error: textStatus, fetchingData: false })
      })
    }
  }

  // Send API data (e.g. to edit page contents) and go to a new URL or refresh page data
  sendApiData = (method, apiURL, data) => {
    this.setState({ fetchingData: true })
    $.getJSON({ type: method, url: apiURL,
                data: _.merge(_.cloneDeep(data),
                        { username: this.state.adminLogin.username, token: this.state.adminLogin.token })})
    .done(data=>{
      if (data.nextURL) {
        this.setState({ fetchingData: false })
        this.props.router.push(data.nextURL)
      }
      else
        this.fetchPageData()
    })
    .fail(data=>{
      alert("Error" + (data.responseJSON ? `:\n${data.responseJSON.message}`
                                         : ` ${data.status}:\n${data.statusText}.`))
      this.fetchPageData()
    })
  }

  // This gets called when props change by switching to a new page.
  // It is *not* called on first-time construction. We use it to fetch new page data
  // for the page being switched to.
  componentWillReceiveProps(nextProps) {
    if (!_.isEqual(this.props, nextProps)) {
      //this.setState(this.getEmptyState())   bad: this causes loss of context when clicking search facets
      this.setState({ fetchingData: true })
      setTimeout(()=>this.fetchPageData(), 0) // fetch right after setting the new props
    }
  }

  // Method to be supplied by derived classes, so they can make a URL that will grab
  // the proper API data from the server.
  pageDataURL() {
    throw "Derived class must override pageDataURL method"
  }

  // Optional method: for editable pages, the unit ID to look up permissions for
  pagePermissionsUnit() {
    return null
  }

  // Method to be supplied by derived classes, so they can make a URL that will grab
  // the proper API data from the server.
  renderData() {
    throw "Derived class must override renderData method"
  }

  renderContent() {
    // Error case
    if (this.state.error) {
      return (
        <div className="body">
          {this.renderError()}
          <FooterComp/>
        </div>)
    }

    // CMS drawer case
    if (this.state.adminLogin && this.state.adminLogin.loggedIn &&
        this.state.cmsModules && this.state.pageData &&
        'header' in this.state.pageData && 'nav_bar' in this.state.pageData.header)
    {
      return (
        <DrawerComp data={this.state.pageData}
                    sendApiData={this.sendApiData}
                    fetchingData={this.state.fetchingData}>
          {/* Not sure why the padding below is needed, but it is */}
          <div className="body" style={{ padding: "10px" }}>
            <SkipNavComp/>
            {this.state.pageData ? this.renderData(this.state.pageData) : this.renderLoading()}
            <FooterComp/>
          </div>
        </DrawerComp>)
    }

    // Normal case
    return (
      <div className="body">
        <SkipNavComp/>
        {this.state.pageData ? this.renderData(this.state.pageData) : this.renderLoading()}
        <FooterComp/>
      </div>)
  }

  fetchPermissions(state) {
    const unit = this.pagePermissionsUnit()
    if (unit
        && state.adminLogin
        && state.adminLogin.loggedIn
        && !state.fetchingPerms
        && !state.permissions) 
    {
      this.setState({ fetchingPerms: true })
      $.getJSON(
        `/api/permissions/${unit}?username=${state.adminLogin.username}&token=${state.adminLogin.token}`)
      .done((data) => {
        if (data.error) {
          this.setSessionData(null)
          this.setState({ fetchingPerms: false, adminLogin: null, permissions: null, isEditingPage: false })
          alert("Login note: " + data.message)
        }
        else {
          this.setState({ fetchingPerms: false, permissions: data })
          if (!state.cmsModules) {
            // Load CMS-specific modules asynchronously
            require.ensure(['react-trumbowyg', 'react-sidebar', 'react-sortable-tree'], (require) => {
              this.setState({ cmsModules: { Trumbowyg: require('react-trumbowyg').default,
                                            Sidebar: require('react-sidebar').default,
                                            SortableTree: require('react-sortable-tree').default } })
            }, "cms") // load from webpack "cms" bundle
          }
        }
      })
      .fail((jqxhr, textStatus, err)=> {
        this.setState({ error: textStatus, fetchingPerms: false, adminLogin: null, permissions: null, isEditingPage: false })
      })
    }
  }

  isStageMachine() {
    let lookFor = /-stg/
    if (lookFor.test(this.props.location.host))
      return true
    else if (!((typeof window) === "undefined") && window.location && lookFor.test(window.location.origin))
      return true
    else
      return false
  }

  stageWatermark() {
    if (!this.isStageMachine())
      return null
    return <TestMessageComp/>
  }

  render() {
    return (
      <div>
        { this.stageWatermark() }
        <Broadcast channel="cms" value={ { loggedIn: this.state.adminLogin && this.state.adminLogin.loggedIn,
                                           username: this.state.adminLogin && this.state.adminLogin.username,
                                           token: this.state.adminLogin && this.state.adminLogin.token,
                                           onLogin: this.onLogin,
                                           onLogout: this.onLogout,
                                           isEditingPage: this.state.adminLogin && this.state.adminLogin.loggedIn && this.state.isEditingPage,
                                           onEditingPageChange: this.onEditingPageChange,
                                           fetchPageData: ()=>this.fetchPageData(this.props),
                                           goLocation: (loc)=>this.props.router.push(loc),
                                           modules: this.state.cmsModules,
                                           permissions: this.state.permissions } }>
          {this.renderContent()}
        </Broadcast>
      </div>
    )
  }

  renderLoading() { return(
    <div>
      <Header1Comp/>
      <h2 style={{ marginTop: "5em", marginBottom: "5em" }}>Loading...</h2>
    </div>
  )}

  renderError() { return (
    <div>
      <Header1Comp/>
      <h2 style={{ marginTop: "5em", marginBottom: "5em" }}>Unable to reach the server: {this.state.error}</h2>
    </div>
  )}

}

module.exports = PageBase
