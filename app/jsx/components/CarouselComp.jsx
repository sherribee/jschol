// ##### Campus Carousel Component ##### //

import React from 'react'
import ReactDOMServer from 'react-dom/server'
import PropTypes from 'prop-types'
import $ from 'jquery'

// Only load flickity when in the browser (not server-side)
if (!(typeof document === "undefined")) {
  var Flickity = require('flickity-imagesloaded')
}

class CarouselComp extends React.Component {
  componentDidMount() {
    try {
      this.flkty = new Flickity(this.domEl.firstChild, this.props.options)
    }
    catch (e) {
      console.log("Exception initializing flickity:", e)
    }
  }

  componentWillUnmount() {
    try {
      if (this.flkty)
        this.flkty.destroy();
    }
    catch (e) {
      console.log("Exception destroying flickity:", e)
    }
  }

  static propTypes = {
    className: PropTypes.string.isRequired,
    options: PropTypes.object.isRequired,
  }
  render() {
    // The 'dangerouslySetInnerHTML' rigarmarole below is to keep React from attaching event handlers
    // to the children, because after Flickity takes over those children, the handlers otherwise become
    // confused and put out warnings to the console.
    return (
      <div className={this.props.className} ref={ el => this.domEl = el }
        dangerouslySetInnerHTML={{__html: ReactDOMServer.renderToStaticMarkup(<div>{this.props.children}</div>)}}/>
    )
  }
}

module.exports = CarouselComp;
