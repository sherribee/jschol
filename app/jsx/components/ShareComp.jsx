// ##### Share Component ##### //

import React from 'react'
import $ from 'jquery'

class ShareComp extends React.Component {
  getLink = (type, id, service) => {
    $.getJSON("/api/mediaLink/"+type+"/"+id+"/"+service).done((data) => {
      window.location = data.url
    }).fail((jqxhr, textStatus, err)=> {
      console.log("Failed! textStatus=", textStatus, ", err=", err)
    })
  }

  render() {
    let p = this.props
    return (
      <details className="c-share">
        <summary><span>Share</span></summary>
        <div className="c-share__list">
          <a className="c-share__email" href="#" onClick={() => {this.getLink(p.type, p.id, "email")}}>Email</a>
          <a className="c-share__facebook" href="#" onClick={() => {this.getLink(p.type, p.id, "facebook")}}>Facebook</a>
          <a className="c-share__twitter" href="#" onClick={() => {this.getLink(p.type, p.id, "twitter")}}>Twitter</a>
        </div>
      </details>
    )
  }
}

module.exports = ShareComp;
