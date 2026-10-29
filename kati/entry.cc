// ios_system entry point for `make`: kati, a GNU make clone.
int kati_main(int argc, char* argv[]);

extern "C" __attribute__((visibility("default"))) int operator_kati_main(int argc, char** argv) {
  return kati_main(argc, argv);
}
