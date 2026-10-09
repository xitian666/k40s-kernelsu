#!/bin/bash
# Patches author: weishu <twsxtd@gmail.com>
# Shell authon: xiaoleGun <1592501605@qq.com>
#               bdqllW <bdqllT@gmail.com>
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9
# 20240123

patch_files=(
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    drivers/input/input.c
)

for i in "${patch_files[@]}"; do

    if grep -q "ksu" "$i"; then
        echo "Warning: $i contains KernelSU"
        continue
    fi

    case $i in

    # fs/ changes
    ## exec.c
    fs/exec.c)
        sed -i '/static int do_execveat_common/i\#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n			void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n				 void *argv, void *envp, int *flags);\n#endif' fs/exec.c
        if grep -q "return __do_execve_file(fd, filename, argv, envp, flags, NULL);" fs/exec.c; then
            sed -i '/return __do_execve_file(fd, filename, argv, envp, flags, NULL);/i\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_execveat_hook))\n		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n	else\n		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n	#endif' fs/exec.c
        else
            sed -i '/if (IS_ERR(filename))/i\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_execveat_hook))\n		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n	else\n		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n	#endif' fs/exec.c
        fi
        ;;

    ## open.c
    fs/open.c)
        if grep -q "long do_faccessat(int dfd, const char __user \*filename, int mode)" fs/open.c; then
            sed -i '/long do_faccessat(int dfd, const char __user \*filename, int mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
        else
            sed -i '/SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
        fi
        sed -i '/if (mode & ~S_IRWXO)/i\	#ifdef CONFIG_KSU\n	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n	#endif\n' fs/open.c
        ;;

    ## read_write.c
    fs/read_write.c)
        sed -i '/ssize_t vfs_read(struct file/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n		size_t *count_ptr, loff_t **pos);\n#endif' fs/read_write.c
        sed -i '/ssize_t vfs_read(struct file/,/ssize_t ret;/{/ssize_t ret;/a\
        #ifdef CONFIG_KSU\
        if (unlikely(ksu_vfs_read_hook))\
            ksu_handle_vfs_read(&file, &buf, &count, &pos);\
        #endif
        }' fs/read_write.c
        ;;

    ## stat.c
    fs/stat.c)
        if grep -q "int vfs_statx(int dfd, const char __user \*filename, int flags," fs/stat.c; then
            sed -i '/int vfs_statx(int dfd, const char __user \*filename, int flags,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
            sed -i '/unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\\n	#ifdef CONFIG_KSU\n	ksu_handle_stat(&dfd, &filename, &flags);\n	#endif' fs/stat.c
        else
            sed -i '/int vfs_fstatat(int dfd, const char __user \*filename, struct kstat \*stat,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
            sed -i '/if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |/i\	#ifdef CONFIG_KSU\n	ksu_handle_stat(&dfd, &filename, &flag);\n	#endif\n' fs/stat.c
        fi
        ;;

    # drivers/input changes
    ## input.c
    drivers/input/input.c)
        sed -i '/static void input_handle_event/i\#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif\n' drivers/input/input.c
        sed -i '/int disposition = input_get_disposition(dev, type, code, &value);/a\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_input_hook))\n		ksu_handle_input_handle_event(&type, &code, &value);\n	#endif' drivers/input/input.c
        ;;
    esac

done

# ---- 追加修复：强制定义 KSU 签名宏（编译环境变量未传递问题）----
if [ -f drivers/kernelsu/apk_sign.c ]; then
    echo "[patch] injecting EXPECTED_SIZE/EXPECTED_HASH macros"
    sed -i '1i #ifndef EXPECTED_SIZE\n#define EXPECTED_SIZE 0x033b\n#endif' drivers/kernelsu/apk_sign.c
    sed -i '1i #ifndef EXPECTED_HASH\n#define EXPECTED_HASH "c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6"\n#endif' drivers/kernelsu/apk_sign.c
    head -12 drivers/kernelsu/apk_sign.c
fi

# ---- 追加修复2：KSU v0.9.5 SELinux 兼容性（4.19 内核）----
if [ -f drivers/kernelsu/selinux/selinux.c ]; then
    echo "[patch2] fixing KSU selinux.c for 4.19 kernel"
    # 1) selinux_enforcing 在外部声明（内核安全模块里导出）
    sed -i '1i #ifndef selinux_enforcing\nextern int selinux_enforcing;\n#endif' drivers/kernelsu/selinux/selinux.c
    # 2) 删除与内核冲突的 current_sid 定义
    python3 - <<'PYINNER'
import re
p='drivers/kernelsu/selinux/selinux.c'
s=open(p).read()
s=re.sub(r'static inline u32 current_sid\(void\)\s*\{[^}]*\}', '', s, count=1)
open(p,'w').write(s)
print('[patch2] removed duplicate current_sid')
PYINNER
    head -8 drivers/kernelsu/selinux/selinux.c
fi
