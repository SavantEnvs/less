/*
 * Wrapper main for the less targets whose untrusted input is named by an environment variable
 * rather than by a command-line argument. less's own main (main.c, compiled with
 * -Dmain=less_main into a separate object) does all the work; this only sets one variable and
 * builds less's argv.
 *
 *   less_env opts    FILE   LESS=<contents of FILE>, then: less --tty=/dev/null FILE
 *                           (the option string less reads from $LESS: option.c scan_option,
 *                           optfunc.c handlers such as -x tab stops, -D colors, -P prompts;
 *                           the same file is then displayed with those options)
 *   less_env history FILE   LESSHISTFILE=FILE, then: less --tty=/dev/null FILE
 *                           (cmdbuf.c read_cmdhist: the .less-history-file sections and
 *                           mark.c restore_mark)
 *   less_env tags    FILE   copies FILE to "tags" in a fresh mkdtemp directory under $TMPDIR,
 *                           chdir()s there, then: less --tty=/dev/null -T tags -t main
 *                           (tags.c findctag/getentry/ctagsearch). The tag entries name files
 *                           relative to the cwd, so an entry naming "tags" points back into the
 *                           fuzzed file itself. The directory is removed at exit.
 *
 * Everything else (LESSSECURE, TERM, screen size, ...) comes from the Mayhemfile env.
 * less ends every run in exit() (quit()), so this is a file-input (AFL) target, not libFuzzer.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char tagdir[4096];
static char tagpath[4096 + 8];

static void remove_tagdir(void)
{
	unlink(tagpath);
	rmdir(tagdir);
}

/* Copy src to dst byte for byte; 0 on success. */
static int copy_file(const char *src, const char *dst)
{
	FILE *in = fopen(src, "rb");
	FILE *out;
	char buf[8192];
	size_t n;
	int rc = 0;
	if (in == NULL)
		return -1;
	out = fopen(dst, "wb");
	if (out == NULL)
	{
		fclose(in);
		return -1;
	}
	while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
		if (fwrite(buf, 1, n, out) != n)
			rc = -1;
	if (ferror(in))
		rc = -1;
	fclose(in);
	if (fclose(out) != 0)
		rc = -1;
	return rc;
}

int less_main(int argc, const char *argv[]);

static char *read_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	char *buf;
	size_t n = 0, cap = 4096;
	int c;
	if (f == NULL)
		return NULL;
	buf = malloc(cap);
	if (buf == NULL)
		exit(1);
	/* An environment variable cannot hold a NUL; it ends the value, as it would in a shell. */
	while ((c = getc(f)) != EOF && c != '\0')
	{
		if (n + 1 >= cap && (buf = realloc(buf, cap *= 2)) == NULL)
			exit(1);
		buf[n++] = (char) c;
	}
	buf[n] = '\0';
	fclose(f);
	return buf;
}

int main(int argc, char *argv[])
{
	const char *largv[7];
	if (argc != 3)
	{
		fprintf(stderr, "usage: %s opts|history|tags FILE\n", argv[0]);
		return 2;
	}
	if (strcmp(argv[1], "opts") == 0)
	{
		char *s = read_file(argv[2]);
		if (s == NULL)
		{
			perror(argv[2]);
			return 2;
		}
		setenv("LESS", s, 1);
		free(s);
	} else if (strcmp(argv[1], "history") == 0)
	{
		setenv("LESSHISTFILE", argv[2], 1);
	} else if (strcmp(argv[1], "tags") == 0)
	{
		const char *tmp = getenv("TMPDIR");
		if (tmp == NULL || *tmp == '\0')
			tmp = "/tmp";
		if ((size_t) snprintf(tagdir, sizeof(tagdir), "%s/less_tags.XXXXXX", tmp) >= sizeof(tagdir)
		    || mkdtemp(tagdir) == NULL)
		{
			perror("mkdtemp");
			return 2;
		}
		snprintf(tagpath, sizeof(tagpath), "%s/tags", tagdir);
		atexit(remove_tagdir);
		if (copy_file(argv[2], tagpath) != 0 || chdir(tagdir) != 0)
		{
			perror(argv[2]);
			return 2;
		}
		largv[0] = "less";
		largv[1] = "--tty=/dev/null";
		largv[2] = "-T";
		largv[3] = "tags";
		largv[4] = "-t";
		largv[5] = "main";
		largv[6] = NULL;
		return less_main(6, largv);
	} else
	{
		fprintf(stderr, "unknown mode %s\n", argv[1]);
		return 2;
	}
	largv[0] = "less";
	largv[1] = "--tty=/dev/null";
	largv[2] = argv[2];
	largv[3] = NULL;
	return less_main(3, largv);
}
