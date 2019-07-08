void myWait() {
  for (volatile int i = 0; i < 4000000; ++i) {
  }
  const void (*initFlash)(void) = (void (*)(void))0x08001fd1;
  initFlash();
}
