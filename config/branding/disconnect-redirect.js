// Sends the browser to the session-ended page when the desktop disconnects.
//
// KasmVNC only navigates to disconnected.html on an idle-session timeout; an
// ordinary disconnect — the user logging out, the display server restarting —
// just shows a small in-page status bar. That meant the session-ended page,
// with its sign-out link and its reminder that the machine is still billing,
// was never seen by anyone who logged out.
//
// The bundle marks connection state by toggling a class on <html>, which is a
// far more stable thing to depend on than anything inside a content-hashed
// script. brand-www.sh asserts both class names exist at build time, so a
// KasmVNC release that renames them fails the build rather than silently
// restoring the old behaviour.
(function () {
  var everConnected = false;
  var navigating = false;

  function check() {
    var classes = document.documentElement.classList;

    if (classes.contains('noVNC_connected')) {
      everConnected = true;
    }

    // Only after a real session: the page is briefly "disconnected" before it
    // has connected for the first time, and redirecting then would bounce
    // anyone who simply opened the page.
    if (!everConnected || navigating) {
      return;
    }

    if (classes.contains('noVNC_disconnected')) {
      navigating = true;
      // A short delay so a momentary state change on the way to reconnecting
      // does not throw the user out of a session that was coming back.
      window.setTimeout(function () {
        if (document.documentElement.classList.contains('noVNC_disconnected')) {
          window.location.replace('disconnected.html');
        } else {
          navigating = false;
        }
      }, 750);
    }
  }

  new MutationObserver(check).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['class']
  });

  check();
})();
