/* Leak detection is off for every target (SPEC §6.2 item 15); ASan and UBSan stay on. */
int __lsan_is_turned_off(void) { return 1; }
