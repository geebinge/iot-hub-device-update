/**
 * @file root_key_list.h
 * @brief Defines functions for getting the hardcoded root keys
 *
 * @copyright Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 */
#ifndef ROOT_KEY_LIST_H
#define ROOT_KEY_LIST_H

#include <umock_c/umock_c_prod.h>

typedef struct tagRSARootKey
{
    const char* kid;
    const char* N;
    const unsigned int e;
} RSARootKey;

MOCKABLE_FUNCTION(, const RSARootKey*,RootKeyList_GetHardcodedRsaRootKeys,)

#endif // ROOT_KEY_LIST_H