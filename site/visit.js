// Pings the owner whenever someone lands on the site. One line, best-effort, never blocks or
// throws: if it fails (ad blocker, private browsing, offline) the page just doesn't report itself.
(function () {
  try {
    var id;
    try {
      id = localStorage.getItem('bvid');
      if (!id) { id = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()); localStorage.setItem('bvid', id); }
    } catch (e) {
      id = String(Date.now()) + Math.random(); // localStorage blocked: still report this one visit
    }
    fetch('https://dzfnetcoyxjyjtmorfgk.supabase.co/functions/v1/track-visit', {
      method: 'POST',
      headers: { apikey: 'sb_publishable_6LwInbn32Vkcz5LbX5O6Bg_-id7TuFQ', 'Content-Type': 'application/json' },
      body: JSON.stringify({ page: location.pathname, visitor: id, referrer: document.referrer || null }),
      keepalive: true,
    }).catch(function () {});
  } catch (e) {}
})();
