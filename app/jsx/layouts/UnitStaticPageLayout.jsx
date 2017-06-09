import React from 'react'
import { Link } from 'react-router'
import { Subscriber } from 'react-broadcast'

import EditableMainContentComp from '../components/EditableMainContentComp.jsx'

class UnitStaticPageLayout extends React.Component {
  onSaveContent(newText, cms) {
    return $
      .ajax({ url: `/api/unit/${this.props.unit.id}/${this.props.data.slug}`,
            type: 'PUT', data: { username: cms.username, token: cms.token, newText: newText }})
      .done(()=>{
        this.props.fetchPageData()  // re-fetch page state after DB is updated
      })
  }

  render() {
    var data = this.props.data;
    return (
      <div className="c-columns">
        <main id="maincontent">
          <Subscriber channel="cms">
            { cms =>
              <EditableMainContentComp onSave={(newText)=>this.onSaveContent(newText, cms)}
                html={data.attrs.html} title={data.title}/>
            }
          </Subscriber>
        </main>
        <aside>
          {this.props.sidebar}
        </aside>
      </div>
    )
  }
}

module.exports = UnitStaticPageLayout