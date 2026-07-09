import NProgress from 'nprogress';
import 'nprogress/nprogress.css';

NProgress.configure({
  easing: 'ease', // animation easing
  speed: 1000, // increment speed
  showSpinner: false, // whether to show the loading spinner
  trickleSpeed: 200, // auto-increment interval
  minimum: 0.3, // minimum percentage at start
  parent: 'body', // parent container for the progress bar
});

// Start the progress bar.
export const start = () => {
  NProgress.start();
};

// Stop the progress bar.
export const close = () => {
  NProgress.done();
};
