#ifndef CRCLONE_H
#define CRCLONE_H

// Mirrors the generated librclone.h. The library is loaded with dlopen, so only types live here.

typedef struct RcloneRPCResult {
    char *Output;
    int Status;
} RcloneRPCResult;

typedef void (*RcloneInitializeFn)(void);
typedef void (*RcloneFinalizeFn)(void);
typedef RcloneRPCResult (*RcloneRPCFn)(char *method, char *input);
typedef void (*RcloneFreeStringFn)(char *str);

#endif
