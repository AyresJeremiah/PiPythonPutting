(() => {
  const img = document.getElementById('video');
  const canvas = document.getElementById('overlay');
  const ctx = canvas.getContext('2d');
  const elState = document.getElementById('state');
  const elStatus= document.getElementById('status');
  const elMPH   = document.getElementById('mph');
  const elYPS   = document.getElementById('yps');
  const elHLA   = document.getElementById('hla');
  const elFPS   = document.getElementById('fps');

  function fitCanvas() {
    canvas.width  = img.clientWidth;
    canvas.height = img.clientHeight;
  }
  window.addEventListener('resize', fitCanvas);
  img.addEventListener('load', fitCanvas);
  fitCanvas();

  function drawRect(rc, color, label) {
    if (!rc) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.strokeRect(rc.x1, rc.y1, rc.x2-rc.x1, rc.y2-rc.y1);
    if (label) {
      ctx.fillStyle = color;
      ctx.font = '14px system-ui, sans-serif';
      ctx.fillText(label, rc.x1+6, rc.y1+18);
    }
  }
  function drawDot(x, y, r, color) {
    ctx.beginPath();
    ctx.arc(x, y, r || 5, 0, Math.PI*2);
    ctx.fillStyle = color;
    ctx.fill();
  }
  function setStatus(state, centerPresent) {
    elState.textContent = state || 'IDLE';
    let c = 'yellow';
    if (state === 'TRACKING') c = 'green';
    if (state === 'COOLDOWN') c = 'yellow';
    if (state && state.startsWith('SHOT')) c = 'red';
    if (!centerPresent) c = 'yellow';
    elStatus.className = `dot ${c}`;
  }

  const proto = (location.protocol === 'https:') ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.onmessage = (ev) => {
    let data; try { data = JSON.parse(ev.data) } catch { return; }
    const W = (data.dims && data.dims.w) || img.naturalWidth || canvas.width;
    const H = (data.dims && data.dims.h) || img.naturalHeight || canvas.height;
    const sx = canvas.width / (W || 1);
    const sy = canvas.height / (H || 1);

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const stage = data.stage, track = data.track;
    drawRect(stage && {
      x1: Math.round(stage.x1 * sx), y1: Math.round(stage.y1 * sy),
      x2: Math.round(stage.x2 * sx), y2: Math.round(stage.y2 * sy)
    }, '#0ff', 'STAGE');
    drawRect(track && {
      x1: Math.round(track.x1 * sx), y1: Math.round(track.y1 * sy),
      x2: Math.round(track.x2 * sx), y2: Math.round(track.y2 * sy)
    }, '#0f0', 'TRACK');

    if (data.ball && typeof data.ball.x === 'number') {
      drawDot(data.ball.x * sx, data.ball.y * sy, 5, '#fff');
    }

    elMPH.textContent = (data.mph ?? 0).toFixed(1);
    elYPS.textContent = (data.yps ?? 0).toFixed(2);
    elHLA.textContent = ((data.hla ?? 0)).toFixed(1) + '°';
    elFPS.textContent = Math.round(data.fps ?? 0);

    setStatus(data.state, !!data.ball);
  };
})();
