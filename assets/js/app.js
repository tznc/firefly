import "phoenix_html";

// == COMPONENTS ==
import Posts from "./components/posts";
import Attachments from "./components/attachments";
import Times from "./components/times";
import Analytics from "./components/analytics";
// == END COMPONENTS ==

// == USING COMPONENTS ==
// ==== POSTS ====
// Decorate posts
Posts.decorate();
// Preview markdown
Posts.preview();
// Handle attachments for posts
Attachments.mount();
// Report to Segment
Analytics.report();
// ==== END POSTS ====
//
// Pretty up times
Times.humanize();
// == END USING COMPONENTS ==
