import React from 'react'
import { Link } from 'react-router'
import Form from 'react-router-form'

import PageBase from './PageBase.jsx'
import Header1Comp from '../components/Header1Comp.jsx'
import Nav1Comp from '../components/Nav1Comp.jsx'
import FooterComp from '../components/FooterComp.jsx'

let sessionStorage = (typeof window != "undefined") ? window.sessionStorage : null

class LoginSuccessPage extends PageBase
{
  pageDataURL(props) { return null /* no API data */ }

  handlePageEntry(nextState, replaceState) {
    console.log("nextState=", nextState)
  }

  render() { return(
    <div>
      <Header1Comp admin={this.state.admin}/>
      <Nav1Comp />
      <div className="c-columns">
        <main>
          <section className="o-columnbox1">
            <header>
              <h1 className="o-columnbox1__heading">Login Success</h1>
            </header>
            <p>
            You are logged in as '{this.state.admin.username}'.
            </p>
          </section>
        </main>
      </div>
      <FooterComp admin={this.state.admin}/>
    </div>
  )}
}

module.exports = LoginSuccessPage
