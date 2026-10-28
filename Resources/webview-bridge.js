/* Runs in the loaded Globi page through WKWebView.evaluateJavaScript.
   Only DOM form actions; no challenge/token manipulation. */
(() => {
  function fillAndSubmit(plate) {
    const form = document.querySelector('#inspectionForm');
    const input = form?.querySelector('#inspectionPlate');
    const button = form?.querySelector('#inspectionSubmit');
    if (!form || !input || !button) return {state:'unsupported_page'};
    if (button.disabled) return {state:'busy'};
    input.value = plate;
    input.dispatchEvent(new Event('input',{bubbles:true}));
    input.dispatchEvent(new Event('change',{bubbles:true}));
    form.requestSubmit(button);
    return {state:'submitted'};
  }
  function readResult() {
    const error = document.querySelector('#inspectionAlert');
    if (error && !error.classList.contains('d-none') && error.innerText.trim()) {
      return {state:'error',message:error.innerText.trim()};
    }
    const title = document.querySelector('#inspectionResultTitle');
    if (!title) return {state:'pending'};
    return {state:'result',text:document.querySelector('#inspectionResult').innerText,url:location.href};
  }
  window.carDeadlinesBridge = {fillAndSubmit,readResult};
})();
