/**
 * Toast notification system for the playground
 */

const TOAST_TYPES = {
  error: {
    icon: "\u2716",
    className: "toast-error",
  },
  warning: {
    icon: "\u26a0",
    className: "toast-warning",
  },
  success: {
    icon: "\u2714",
    className: "toast-success",
  },
  info: {
    icon: "\u2139",
    className: "toast-info",
  },
};

const DEFAULT_DURATION = 5000;
const ANIMATION_DURATION = 300;

let container = null;

function ensureContainer() {
  if (!container) {
    container = document.getElementById("toast-container");
    if (!container) {
      container = document.createElement("div");
      container.id = "toast-container";
      document.body.appendChild(container);
    }
  }
  return container;
}

/**
 * Show a toast notification
 * @param {string} message - The message to display
 * @param {object} options - Toast options
 * @param {'error'|'warning'|'success'|'info'} options.type - Toast type (default: 'info')
 * @param {number} options.duration - Duration in ms (default: 5000, 0 = persistent)
 * @returns {function} - Function to manually dismiss the toast
 */
export function showToast(message, options = {}) {
  const { type = "info", duration = DEFAULT_DURATION } = options;
  const typeConfig = TOAST_TYPES[type] || TOAST_TYPES.info;

  const toastContainer = ensureContainer();

  const toast = document.createElement("div");
  toast.className = `toast ${typeConfig.className}`;
  toast.innerHTML = `
    <span class="toast-icon">${typeConfig.icon}</span>
    <span class="toast-message">${escapeHtml(message)}</span>
    <div class="toast-actions">
      <button class="toast-copy" aria-label="Copy">\u2398</button>
      <button class="toast-close" aria-label="Dismiss">\u2715</button>
    </div>
  `;

  const dismiss = () => {
    if (!toast.parentNode) return;
    toast.classList.add("toast-exit");
    setTimeout(() => {
      if (toast.parentNode) {
        toast.parentNode.removeChild(toast);
      }
    }, ANIMATION_DURATION);
  };

  const copyBtn = toast.querySelector(".toast-copy");
  copyBtn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(message);
      copyBtn.textContent = "\u2714";
      copyBtn.classList.add("copied");
      setTimeout(() => {
        copyBtn.textContent = "\u2398";
        copyBtn.classList.remove("copied");
      }, 1500);
    } catch (err) {
      console.error("Failed to copy toast message:", err);
    }
  });

  toast.querySelector(".toast-close").addEventListener("click", dismiss);

  toastContainer.appendChild(toast);

  // Trigger enter animation
  requestAnimationFrame(() => {
    toast.classList.add("toast-enter");
  });

  if (duration > 0) {
    setTimeout(dismiss, duration);
  }

  return dismiss;
}

/**
 * Show an error toast
 * @param {string} message - Error message
 * @param {object} options - Additional options
 */
export function showError(message, options = {}) {
  return showToast(message, { ...options, type: "error", duration: options.duration ?? 7000 });
}

/**
 * Show a warning toast
 * @param {string} message - Warning message
 * @param {object} options - Additional options
 */
export function showWarning(message, options = {}) {
  return showToast(message, { ...options, type: "warning" });
}

/**
 * Show a success toast
 * @param {string} message - Success message
 * @param {object} options - Additional options
 */
export function showSuccess(message, options = {}) {
  return showToast(message, { ...options, type: "success", duration: options.duration ?? 3000 });
}

/**
 * Show an info toast
 * @param {string} message - Info message
 * @param {object} options - Additional options
 */
export function showInfo(message, options = {}) {
  return showToast(message, { ...options, type: "info" });
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}
