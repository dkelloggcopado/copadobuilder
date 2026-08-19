const bufferModule = require('buffer');
const { Buffer } = bufferModule;

function SlowBuffer(length) {
  const buf = Buffer.allocUnsafeSlow(length);
  Object.setPrototypeOf(buf, SlowBuffer.prototype);
  return buf;
}

SlowBuffer.prototype = Object.create(Buffer.prototype);
SlowBuffer.prototype.equal = function equal(other) {
  if (!Buffer.isBuffer(other)) {
    return false;
  }
  if (this.length !== other.length) {
    return false;
  }
  return this.compare(other) === 0;
};

global.SlowBuffer = SlowBuffer;
bufferModule.SlowBuffer = SlowBuffer;
