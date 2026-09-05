// Delegated confirm() for any form with data-confirm — kept in an external,
// same-origin file (rather than an inline onsubmit handler) because the
// CSP's script-src-attr blocks inline event handler attributes.
document.addEventListener('submit', (event) => {
  const form = event.target.closest('form[data-confirm]');
  if (form && !window.confirm(form.dataset.confirm)) {
    event.preventDefault();
  }
});
