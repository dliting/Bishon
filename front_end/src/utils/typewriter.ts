// Typewriter queue.
export class Typewriter {
  private queue: string[] = [];
  private consuming = false;
  private timmer: any;
  constructor(private onConsume: (str: string) => void) {}
  // Dynamic output-speed control.
  dynamicSpeed() {
    const speed = 2000 / this.queue.length;
    if (speed > 200) {
      return 200;
    } else {
      return speed;
    }
  }
  // Append a string to the queue.
  add(str: string) {
    if (!str) return;
    this.queue.push(...str.split(''));
  }
  // Consume one char.
  consume() {
    if (this.queue.length > 0) {
      const str = this.queue.shift();
      str && this.onConsume(str);
    }
  }
  // Consume the next char.
  next() {
    this.consume();
    // Set the per-frame consumption speed based on the queue length and consume via a timer.
    this.timmer = setTimeout(() => {
      this.consume();
      if (this.consuming) {
        this.next();
      }
    }, this.dynamicSpeed());
  }
  // Start consuming the queue.
  start() {
    this.consuming = true;
    this.next();
  }
  // Stop consuming the queue.
  done() {
    this.consuming = false;
    clearTimeout(this.timmer);
    // Flush the remaining chars in the queue all at once.
    this.onConsume(this.queue.join(''));
    this.queue = [];
  }
}
