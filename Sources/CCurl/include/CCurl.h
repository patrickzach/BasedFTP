#ifndef BASEDFTP_CCURL_H
#define BASEDFTP_CCURL_H
#include <curl/curl.h>
/* Typed adapters for the system library's variadic API, which Swift cannot call. */
static inline CURLcode bftp_long(CURL *c, CURLoption o, long v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode bftp_offset(CURL *c, CURLoption o, curl_off_t v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode bftp_string(CURL *c, CURLoption o, const char *v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode bftp_pointer(CURL *c, CURLoption o, void *v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode bftp_write(CURL *c, curl_write_callback f) { return curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, f); }
static inline CURLcode bftp_read(CURL *c, curl_read_callback f) { return curl_easy_setopt(c, CURLOPT_READFUNCTION, f); }
static inline CURLcode bftp_seek(CURL *c, curl_seek_callback f) { return curl_easy_setopt(c, CURLOPT_SEEKFUNCTION, f); }
static inline CURLcode bftp_progress(CURL *c, curl_xferinfo_callback f) { return curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, f); }
static inline CURLcode bftp_quotes(CURL *c, struct curl_slist *v) { return curl_easy_setopt(c, CURLOPT_QUOTE, v); }
#endif
