#include "phonesign.h"

#include "common.h"
#include "json.h"
#include "openssl.h"
#include "macho.h"
#include "bundle.h"
#include <libgen.h>
#include <dirent.h>
#include <getopt.h>

#include <Foundation/Foundation.h>
#import <SSZipArchive/SSZipArchive.h>

int phonesign(const char *app, const char *p12, const char *psw, const char *prov, const char *outFile)
{
    ZTimer gtimer;

    bool bForce = false;
    bool bInstall = false;
    bool bWeakInject = false;
    uint32_t uZipLevel = 0;

    string strCertFile;
    string strPKeyFile;
    string strProvFile;
    string strPassword;
    string strBundleId;
    string strDyLibFile;
    string strOutputFile;
    string strDisplayName;
    string strEntitlementsFile;
    
    
    strPKeyFile = p12;
    strPassword = psw;
    strProvFile = prov;
    strOutputFile = outFile;
//
//    int opt = 0;
//    int argslot = -1;
//    while (-1 != (opt = getopt_long(argc, argv, "dfvhc:k:m:o:ip:e:b:n:z:ql:w", options, &argslot)))
//    {
//        switch (opt)
//        {
//        case 'd':
//            ZLog::SetLogLever(ZLog::E_DEBUG);
//            break;
//        case 'f':
//            bForce = true;
//            break;
//        case 'c':
//            strCertFile = optarg;
//            break;
//        case 'k':
//            strPKeyFile = optarg;
//            break;
//        case 'm':
//            strProvFile = optarg;
//            break;
//        case 'p':
//            strPassword = optarg;
//            break;
//        case 'b':
//            strBundleId = optarg;
//            break;
//        case 'n':
//            strDisplayName = optarg;
//            break;
//        case 'e':
//            strEntitlementsFile = optarg;
//            break;
//        case 'l':
//            strDyLibFile = optarg;
//            break;
//        case 'i':
//            bInstall = true;
//            break;
//        case 'o':
//            strOutputFile = GetCanonicalizePath(optarg);
//            break;
//        case 'z':
//            uZipLevel = atoi(optarg);
//            break;
//        case 'w':
//            bWeakInject = true;
//            break;
//        case 'q':
//            ZLog::SetLogLever(ZLog::E_NONE);
//            break;
//        case 'v':
//        {
//            printf("version: 0.2\n");
//            return 0;
//        }
//        break;
//        case 'h':
//        case '?':
//            return usage();
//            break;
//        }
//
//        ZLog::DebugV(">>> Option:\t-%c, %s\n", opt, optarg);
//    }
//
//    if (optind >= argc)
//    {
//        return usage();
//    }

//    if (ZLog::IsDebug())
//    {
//        CreateFolder("./.zsign_debug");
//        for (int i = optind; i < argc; i++)
//        {
//            ZLog::DebugV(">>> Argument:\t%s\n", argv[i]);
//        }
//    }

    string strPath = GetCanonicalizePath(app);
    if (!IsFileExists(strPath.c_str()))
    {
        ZLog::ErrorV(">>> Invalid Path! %s\n", strPath.c_str());
        return -1;
    }

    bool bZipFile = false;
    if (!IsFolder(strPath.c_str()))
    {
        bZipFile = IsZipFile(strPath.c_str());
        if (!bZipFile)
        { //macho file
            ZMachO macho;
            if (macho.Init(strPath.c_str()))
            {
                if(!strDyLibFile.empty())
                {//inject dylib
                    bool bCreate = false;
                    macho.InjectDyLib(bWeakInject, strDyLibFile.c_str(), bCreate);
                }
                else
                {
                    macho.PrintInfo();
                }
                macho.Free();
            }
            return 0;
        }
    }

    ZTimer timer;
    ZSignAsset zSignAsset;
    if (!zSignAsset.Init(strCertFile, strPKeyFile, strProvFile, strEntitlementsFile, strPassword))
    {
        return -1;
    }

    bool bEnableCache = true;
    string strFolder = strPath;
    if (bZipFile)
    { //ipa file
        bForce = true;
        bEnableCache = false;
        
        const char *temp = [[[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, true).firstObject stringByAppendingPathComponent:@"PhoneSign"] stringByAppendingFormat:@"zsign_folder_%llu", timer.Reset()] UTF8String];
        
        
//        StringFormat(strFolder, "/tmp/zsign_folder_%llu", timer.Reset());
        StringFormat(strFolder, temp);
        ZLog::PrintV(">>> Unzip:\t%s (%s) -> %s ... \n", strPath.c_str(), GetFileSizeString(strPath.c_str()).c_str(), strFolder.c_str());
        RemoveFolder(strFolder.c_str());
        
        
        BOOL success = [SSZipArchive unzipFileAtPath: [[NSString alloc] initWithUTF8String:strPath.c_str()]
                                       toDestination:[[NSString alloc] initWithUTF8String:strFolder.c_str()]
                                  preserveAttributes:YES
                                           overwrite:YES
                                      nestedZipLevel:0
                                            password:nil
                                               error:nil
                                            delegate:nil
                                     progressHandler:nil
                                   completionHandler:nil];
//        if (!SystemExec("unzip -qq -d '%s' '%s'", strFolder.c_str(), strPath.c_str()))
        if (!success)
        {
            RemoveFolder(strFolder.c_str());
            ZLog::ErrorV(">>> Unzip Failed!\n");
            return -1;
        }
        timer.PrintResult(true, ">>> Unzip OK!");
    }

    timer.Reset();
    ZAppBundle bundle;
    bool bRet = bundle.SignFolder(&zSignAsset, strFolder, strBundleId, strDisplayName, strDyLibFile, bForce, bWeakInject, bEnableCache);
    timer.PrintResult(bRet, ">>> Signed %s!", bRet ? "OK" : "Failed");

    if (bInstall && strOutputFile.empty())
    {
        StringFormat(strOutputFile, "/tmp/zsign_temp_%llu.ipa", GetMicroSecond());
    }

    if (!strOutputFile.empty())
    {
        timer.Reset();
        size_t pos = bundle.m_strAppFolder.rfind("/Payload");
        if (string::npos == pos)
        {
            ZLog::Error(">>> Can't Find Payload Directory!\n");
            return -1;
        }

        ZLog::PrintV(">>> Archiving: \t%s ... \n", strOutputFile.c_str());
        string strBaseFolder = bundle.m_strAppFolder.substr(0, pos);
        char szOldFolder[PATH_MAX] = {0};
        if (NULL != getcwd(szOldFolder, PATH_MAX))
        {
            if (0 == chdir(strBaseFolder.c_str()))
            {
                uZipLevel = uZipLevel > 9 ? 9 : uZipLevel;
                RemoveFile(strOutputFile.c_str());
                
                [SSZipArchive createZipFileAtPath:[[NSString alloc] initWithUTF8String:strOutputFile.c_str()]
                                         withContentsOfDirectory:@""
                                             keepParentDirectory:NO
                                                compressionLevel:-1
                                                        password:nil
                                                             AES:YES
                                                 progressHandler:nil];
                SystemExec("zip -q -%u -r '%s' Payload", uZipLevel, strOutputFile.c_str());
                chdir(szOldFolder);
                if (!IsFileExists(strOutputFile.c_str()))
                {
                    ZLog::Error(">>> Archive Failed!\n");
                    return -1;
                }
            }
        }
        timer.PrintResult(true, ">>> Archive OK! (%s)", GetFileSizeString(strOutputFile.c_str()).c_str());
    }

    if (bRet && bInstall)
    {
        SystemExec("ideviceinstaller -i '%s'", strOutputFile.c_str());
    }

    if (0 == strOutputFile.find("/tmp/zsign_tmp_"))
    {
        RemoveFile(strOutputFile.c_str());
    }

    if (0 == strFolder.find("/tmp/zsign_folder_"))
    {
        RemoveFolder(strFolder.c_str());
    }

    gtimer.Print(">>> Done.");
    return bRet ? 0 : -1;
}
