// ##### Search Component ##### //

import React from 'react'
import Form from 'react-router-form'

class SearchComp1 extends React.Component {
  render() {
    return (
      <Form to='/search' method="GET" className="c-search1">
        <div className="c-search1__form">
          <label className="c-search1__label" htmlFor="global-search">Search eScholarship</label>
          <input type="search" id="global-search" name="q" className="c-search1__field" placeholder="Search eScholarship"/>
          <button type="submit" className="c-search1__submit-button" aria-label="search"></button>
          <button className="c-search1__search-close-button" aria-label="close search field" onClick = {()=>this.props.onClose()}></button>
        </div>
        <div className="c-search1__tagline">
          Open Access publications from the University of California
        </div>
      </Form>
    )
  }
}

module.exports = SearchComp1;