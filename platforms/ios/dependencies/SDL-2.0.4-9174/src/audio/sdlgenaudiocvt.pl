#!/usr/bin/perl -w

use warnings;
use strict;

my @audiotypes = qw(
    U8
    S8
    U16LSB
    S16LSB
    U16MSB
    S16MSB
    S32LSB
    S32MSB
    F32LSB
    F32MSB
);

my @channels = ( 1, 2, 4, 6, 8 );
my %funcs;
my $custom_converters = 0;


sub getTypeConvertHashId {
    my ($from, $to) = @_;
    return "TYPECONVERTER $from/$to";
}


sub getResamplerHashId {
    my ($from, $channels, $upsample, $multiple) = @_;
    return "RESAMPLER $from/$channels/$upsample/$multiple";
}


sub outputHeader {
    print <<EOF;
/* DO NOT EDIT!  This file is generated by sdlgenaudiocvt.pl */
/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2014 Sam Lantinga <slouken\@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/

#include "../SDL_internal.h"
#include "SDL_audio.h"
#include "SDL_audio_c.h"

#ifndef DEBUG_CONVERT
#define DEBUG_CONVERT 0
#endif


/* If you can guarantee your data and need space, you can eliminate code... */

/* Just build the arbitrary resamplers if you're saving code space. */
#ifndef LESS_RESAMPLERS
#define LESS_RESAMPLERS 0
#endif

/* Don't build any resamplers if you're REALLY saving code space. */
#ifndef NO_RESAMPLERS
#define NO_RESAMPLERS 0
#endif

/* Don't build any type converters if you're saving code space. */
#ifndef NO_CONVERTERS
#define NO_CONVERTERS 0
#endif


/* *INDENT-OFF* */

EOF

    my @vals = ( 127, 32767, 2147483647 );
    foreach (@vals) {
        my $val = $_;
        my $fval = 1.0 / $val;
        print("#define DIVBY${val} ${fval}f\n");
    }

    print("\n");
}

sub outputFooter {
    print <<EOF;
/* $custom_converters converters generated. */

/* *INDENT-ON* */

/* vi: set ts=4 sw=4 expandtab: */
EOF
}

sub splittype {
    my $t = shift;
    my ($signed, $size, $endian) = $t =~ /([USF])(\d+)([LM]SB|)/;
    my $float = ($signed eq 'F') ? 1 : 0;
    $signed = (($float) or ($signed eq 'S')) ? 1 : 0;
    $endian = 'NONE' if ($endian eq '');

    my $ctype = '';
    if ($float) {
        $ctype = (($size == 32) ? 'float' : 'double');
    } else {
        $ctype = (($signed) ? 'S' : 'U') . "int${size}";
    }

    return ($signed, $float, $size, $endian, $ctype);
}

sub getSwapFunc {
    my ($size, $signed, $float, $endian, $val) = @_;
    my $BEorLE = (($endian eq 'MSB') ? 'BE' : 'LE');
    my $code = '';

    if ($float) {
        $code = "SDL_SwapFloat${BEorLE}($val)";
    } else {
        if ($size > 8) {
            $code = "SDL_Swap${BEorLE}${size}($val)";
        } else {
            $code = $val;
        }

        if (($signed) and (!$float)) {
            $code = "((Sint${size}) $code)";
        }
    }

    return "${code}";
}


sub maxIntVal {
    my $size = shift;
    if ($size == 8) {
        return 0x7F;
    } elsif ($size == 16) {
        return 0x7FFF;
    } elsif ($size == 32) {
        return 0x7FFFFFFF;
    }

    die("bug in script.\n");
}

sub getFloatToIntMult {
    my $size = shift;
    my $val = maxIntVal($size) . '.0';
    $val .= 'f' if ($size < 32);
    return $val;
}

sub getIntToFloatDivBy {
    my $size = shift;
    return 'DIVBY' . maxIntVal($size);
}

sub getSignFlipVal {
    my $size = shift;
    if ($size == 8) {
        return '0x80';
    } elsif ($size == 16) {
        return '0x8000';
    } elsif ($size == 32) {
        return '0x80000000';
    }

    die("bug in script.\n");
}

sub buildCvtFunc {
    my ($from, $to) = @_;
    my ($fsigned, $ffloat, $fsize, $fendian, $fctype) = splittype($from);
    my ($tsigned, $tfloat, $tsize, $tendian, $tctype) = splittype($to);
    my $diffs = 0;
    $diffs++ if ($fsize != $tsize);
    $diffs++ if ($fsigned != $tsigned);
    $diffs++ if ($ffloat != $tfloat);
    $diffs++ if ($fendian ne $tendian);

    return if ($diffs == 0);

    my $hashid = getTypeConvertHashId($from, $to);
    if (1) { # !!! FIXME: if ($diffs > 1) {
        my $sym = "SDL_Convert_${from}_to_${to}";
        $funcs{$hashid} = $sym;
        $custom_converters++;

        # Always unsigned for ints, for possible byteswaps.
        my $srctype = (($ffloat) ? 'float' : "Uint${fsize}");

        print <<EOF;
static void SDLCALL
${sym}(SDL_AudioCVT * cvt, SDL_AudioFormat format)
{
    int i;
    const $srctype *src;
    $tctype *dst;

#if DEBUG_CONVERT
    fprintf(stderr, "Converting AUDIO_${from} to AUDIO_${to}.\\n");
#endif

EOF

        if ($fsize < $tsize) {
            my $mult = $tsize / $fsize;
            print <<EOF;
    src = ((const $srctype *) (cvt->buf + cvt->len_cvt)) - 1;
    dst = (($tctype *) (cvt->buf + cvt->len_cvt * $mult)) - 1;
    for (i = cvt->len_cvt / sizeof ($srctype); i; --i, --src, --dst) {
EOF
        } else {
            print <<EOF;
    src = (const $srctype *) cvt->buf;
    dst = ($tctype *) cvt->buf;
    for (i = cvt->len_cvt / sizeof ($srctype); i; --i, ++src, ++dst) {
EOF
        }

        # Have to convert to/from float/int.
        # !!! FIXME: cast through double for int32<->float?
        my $code = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, '*src');
        if ($ffloat != $tfloat) {
            if ($ffloat) {
                my $mult = getFloatToIntMult($tsize);
                if (!$tsigned) {   # bump from -1.0f/1.0f to 0.0f/2.0f
                    $code = "($code + 1.0f)";
                }
                $code = "(($tctype) ($code * $mult))";
            } else {
                # $divby will be the reciprocal, to avoid pipeline stalls
                #  from floating point division...so multiply it.
                my $divby = getIntToFloatDivBy($fsize);
                $code = "(((float) $code) * $divby)";
                if (!$fsigned) {   # bump from 0.0f/2.0f to -1.0f/1.0f.
                    $code = "($code - 1.0f)";
                }
            }
        } else {
            # All integer conversions here.
            if ($fsigned != $tsigned) {
                my $signflipval = getSignFlipVal($fsize);
                $code = "(($code) ^ $signflipval)";
            }

            my $shiftval = abs($fsize - $tsize);
            if ($fsize < $tsize) {
                $code = "((($tctype) $code) << $shiftval)";
            } elsif ($fsize > $tsize) {
                $code = "(($tctype) ($code >> $shiftval))";
            }
        }

        my $swap = getSwapFunc($tsize, $tsigned, $tfloat, $tendian, 'val');

        print <<EOF;
        const $tctype val = $code;
        *dst = ${swap};
    }

EOF

        if ($fsize > $tsize) {
            my $divby = $fsize / $tsize;
            print("    cvt->len_cvt /= $divby;\n");
        } elsif ($fsize < $tsize) {
            my $mult = $tsize / $fsize;
            print("    cvt->len_cvt *= $mult;\n");
        }

        print <<EOF;
    if (cvt->filters[++cvt->filter_index]) {
        cvt->filters[cvt->filter_index] (cvt, AUDIO_$to);
    }
}

EOF

    } else {
        if ($fsigned != $tsigned) {
            $funcs{$hashid} = 'SDL_ConvertSigned';
        } elsif ($ffloat != $tfloat) {
            $funcs{$hashid} = 'SDL_ConvertFloat';
        } elsif ($fsize != $tsize) {
            $funcs{$hashid} = 'SDL_ConvertSize';
        } elsif ($fendian ne $tendian) {
            $funcs{$hashid} = 'SDL_ConvertEndian';
        } else {
            die("error in script.\n");
        }
    }
}


sub buildTypeConverters {
    print "#if !NO_CONVERTERS\n\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@audiotypes) {
            my $to = $_;
            buildCvtFunc($from, $to);
        }
    }
    print "#endif  /* !NO_CONVERTERS */\n\n\n";

    print "const SDL_AudioTypeFilters sdl_audio_type_filters[] =\n{\n";
    print "#if !NO_CONVERTERS\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@audiotypes) {
            my $to = $_;
            if ($from ne $to) {
                my $hashid = getTypeConvertHashId($from, $to);
                my $sym = $funcs{$hashid};
                print("    { AUDIO_$from, AUDIO_$to, $sym },\n");
            }
        }
    }
    print "#endif  /* !NO_CONVERTERS */\n";

    print("    { 0, 0, NULL }\n");
    print "};\n\n\n";
}

sub getBiggerCtype {
    my ($isfloat, $size) = @_;

    if ($isfloat) {
        if ($size == 32) {
            return 'double';
        }
        die("bug in script.\n");
    }

    if ($size == 8) {
        return 'Sint16';
    } elsif ($size == 16) {
        return 'Sint32'
    } elsif ($size == 32) {
        return 'Sint64'
    }

    die("bug in script.\n");
}


# These handle arbitrary resamples...44100Hz to 48000Hz, for example.
# Man, this code is skanky.
sub buildArbitraryResampleFunc {
    # !!! FIXME: we do a lot of unnecessary and ugly casting in here, due to getSwapFunc().
    my ($from, $channels, $upsample) = @_;
    my ($fsigned, $ffloat, $fsize, $fendian, $fctype) = splittype($from);

    my $bigger = getBiggerCtype($ffloat, $fsize);
    my $interp = ($ffloat) ? '* 0.5' : '>> 1';

    my $resample = ($upsample) ? 'Upsample' : 'Downsample';
    my $hashid = getResamplerHashId($from, $channels, $upsample, 0);
    my $sym = "SDL_${resample}_${from}_${channels}c";
    $funcs{$hashid} = $sym;
    $custom_converters++;

    my $fudge = $fsize * $channels * 2;  # !!! FIXME
    my $eps_adjust = ($upsample) ? 'dstsize' : 'srcsize';
    my $incr = '';
    my $incr2 = '';
    my $block_align = $channels * $fsize/8;


    # !!! FIXME: DEBUG_CONVERT should report frequencies.
    print <<EOF;
static void SDLCALL
${sym}(SDL_AudioCVT * cvt, SDL_AudioFormat format)
{
#if DEBUG_CONVERT
    fprintf(stderr, "$resample arbitrary (x%f) AUDIO_${from}, ${channels} channels.\\n", cvt->rate_incr);
#endif

    const int srcsize = cvt->len_cvt - $fudge;
    const int dstsize = (int) (((double)(cvt->len_cvt/${block_align})) * cvt->rate_incr) * ${block_align};
    register int eps = 0;
EOF

    my $endcomparison = '!=';

    # Upsampling (growing the buffer) needs to work backwards, since we
    #  overwrite the buffer as we go.
    if ($upsample) {
        $endcomparison = '>=';  # dst > target
        print <<EOF;
    $fctype *dst = (($fctype *) (cvt->buf + dstsize)) - $channels;
    const $fctype *src = (($fctype *) (cvt->buf + cvt->len_cvt)) - $channels;
    const $fctype *target = ((const $fctype *) cvt->buf);
EOF
    } else {
        $endcomparison = '<';  # dst < target
        print <<EOF;
    $fctype *dst = ($fctype *) cvt->buf;
    const $fctype *src = ($fctype *) cvt->buf;
    const $fctype *target = (const $fctype *) (cvt->buf + dstsize);
EOF
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        my $val = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "src[$idx]");
        print <<EOF;
    $fctype sample${idx} = $val;
EOF
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        print <<EOF;
    $fctype last_sample${idx} = sample${idx};
EOF
    }

    print <<EOF;
    while (dst $endcomparison target) {
EOF

    if ($upsample) {
        for (my $i = 0; $i < $channels; $i++) {
            # !!! FIXME: don't do this swap every write, just when the samples change.
            my $idx = (($channels - $i) - 1);
            my $val = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "sample${idx}");
            print <<EOF;
        dst[$idx] = $val;
EOF
        }

        $incr = ($channels == 1) ? 'dst--' : "dst -= $channels";
        $incr2 = ($channels == 1) ? 'src--' : "src -= $channels";

        print <<EOF;
        $incr;
        eps += srcsize;
        if ((eps << 1) >= dstsize) {
            $incr2;
EOF
    } else {  # downsample.
        $incr = ($channels == 1) ? 'src++' : "src += $channels";
        print <<EOF;
        $incr;
        eps += dstsize;
        if ((eps << 1) >= srcsize) {
EOF
        for (my $i = 0; $i < $channels; $i++) {
            my $val = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "sample${i}");
            print <<EOF;
            dst[$i] = $val;
EOF
        }

        $incr = ($channels == 1) ? 'dst++' : "dst += $channels";
        print <<EOF;
            $incr;
EOF
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        my $swapped = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "src[$idx]");
        print <<EOF;
            sample${idx} = ($fctype) (((($bigger) $swapped) + (($bigger) last_sample${idx})) $interp);
EOF
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        print <<EOF;
            last_sample${idx} = sample${idx};
EOF
    }

    print <<EOF;
            eps -= $eps_adjust;
        }
    }
EOF

        print <<EOF;
    cvt->len_cvt = dstsize;
    if (cvt->filters[++cvt->filter_index]) {
        cvt->filters[cvt->filter_index] (cvt, format);
    }
}

EOF

}

# These handle clean resamples...doubling and quadrupling the sample rate, etc.
sub buildMultipleResampleFunc {
    # !!! FIXME: we do a lot of unnecessary and ugly casting in here, due to getSwapFunc().
    my ($from, $channels, $upsample, $multiple) = @_;
    my ($fsigned, $ffloat, $fsize, $fendian, $fctype) = splittype($from);

    my $bigger = getBiggerCtype($ffloat, $fsize);
    my $interp = ($ffloat) ? '* 0.5' : '>> 1';
    my $interp2 = ($ffloat) ? '* 0.25' : '>> 2';
    my $mult3 = ($ffloat) ? '3.0' : '3';
    my $lencvtop = ($upsample) ? '*' : '/';

    my $resample = ($upsample) ? 'Upsample' : 'Downsample';
    my $hashid = getResamplerHashId($from, $channels, $upsample, $multiple);
    my $sym = "SDL_${resample}_${from}_${channels}c_x${multiple}";
    $funcs{$hashid} = $sym;
    $custom_converters++;

    # !!! FIXME: DEBUG_CONVERT should report frequencies.
    print <<EOF;
static void SDLCALL
${sym}(SDL_AudioCVT * cvt, SDL_AudioFormat format)
{
#if DEBUG_CONVERT
    fprintf(stderr, "$resample (x${multiple}) AUDIO_${from}, ${channels} channels.\\n");
#endif

    const int dstsize = cvt->len_cvt $lencvtop $multiple;
EOF

    my $endcomparison = '!=';

    # Upsampling (growing the buffer) needs to work backwards, since we
    #  overwrite the buffer as we go.
    if ($upsample) {
        $endcomparison = '>=';  # dst > target
        print <<EOF;
    $fctype *dst = (($fctype *) (cvt->buf + dstsize)) - $channels * $multiple;
    const $fctype *src = (($fctype *) (cvt->buf + cvt->len_cvt)) - $channels;
    const $fctype *target = ((const $fctype *) cvt->buf);
EOF
    } else {
        $endcomparison = '<';  # dst < target
        print <<EOF;
    $fctype *dst = ($fctype *) cvt->buf;
    const $fctype *src = ($fctype *) cvt->buf;
    const $fctype *target = (const $fctype *) (cvt->buf + dstsize);
EOF
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        my $val = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "src[$idx]");
        print <<EOF;
    $bigger last_sample${idx} = ($bigger) $val;
EOF
    }

    print <<EOF;
    while (dst $endcomparison target) {
EOF

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        my $val = getSwapFunc($fsize, $fsigned, $ffloat, $fendian, "src[$idx]");
        print <<EOF;
        const $bigger sample${idx} = ($bigger) $val;
EOF
    }

    my $incr = '';
    if ($upsample) {
        $incr = ($channels == 1) ? 'src--' : "src -= $channels";
    } else {
        my $amount = $channels * $multiple;
        $incr = "src += $amount";  # can't ever be 1, so no "++" version.
    }


    print <<EOF;
        $incr;
EOF

    # !!! FIXME: This really begs for some Altivec or SSE, etc.
    if ($upsample) {
        if ($multiple == 2) {
            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i + $channels;
                print <<EOF;
        dst[$dsti] = ($fctype) ((sample${i} + last_sample${i}) $interp);
EOF
            }
            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i;
                print <<EOF;
        dst[$dsti] = ($fctype) sample${i};
EOF
            }
        } elsif ($multiple == 4) {
            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i + ($channels * 3);
                print <<EOF;
        dst[$dsti] = ($fctype) ((sample${i} + ($mult3 * last_sample${i})) $interp2);
EOF
            }

            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i + ($channels * 2);
                print <<EOF;
        dst[$dsti] = ($fctype) ((sample${i} + last_sample${i}) $interp);
EOF
            }

            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i + ($channels * 1);
                print <<EOF;
        dst[$dsti] = ($fctype) ((($mult3 * sample${i}) + last_sample${i}) $interp2);
EOF
            }

            for (my $i = $channels-1; $i >= 0; $i--) {
                my $dsti = $i + ($channels * 0);
                print <<EOF;
        dst[$dsti] = ($fctype) sample${i};
EOF
            }
        } else {
            die('bug in program.');  # we only handle x2 and x4.
        }
    } else {  # downsample.
        if ($multiple == 2) {
            for (my $i = 0; $i < $channels; $i++) {
                print <<EOF;
        dst[$i] = ($fctype) ((sample${i} + last_sample${i}) $interp);
EOF
            }
        } elsif ($multiple == 4) {
            # !!! FIXME: interpolate all 4 samples?
            for (my $i = 0; $i < $channels; $i++) {
                print <<EOF;
        dst[$i] = ($fctype) ((sample${i} + last_sample${i}) $interp);
EOF
            }
        } else {
            die('bug in program.');  # we only handle x2 and x4.
        }
    }

    for (my $i = 0; $i < $channels; $i++) {
        my $idx = ($upsample) ? (($channels - $i) - 1) : $i;
        print <<EOF;
        last_sample${idx} = sample${idx};
EOF
    }

    if ($upsample) {
        my $amount = $channels * $multiple;
        $incr = "dst -= $amount";  # can't ever be 1, so no "--" version.
    } else {
        $incr = ($channels == 1) ? 'dst++' : "dst += $channels";
    }

    print <<EOF;
        $incr;
    }

    cvt->len_cvt = dstsize;
    if (cvt->filters[++cvt->filter_index]) {
        cvt->filters[cvt->filter_index] (cvt, format);
    }
}

EOF

}

sub buildResamplers {
    print "#if !NO_RESAMPLERS\n\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@channels) {
            my $channel = $_;
            buildArbitraryResampleFunc($from, $channel, 1);
            buildArbitraryResampleFunc($from, $channel, 0);
        }
    }

    print "\n#if !LESS_RESAMPLERS\n\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@channels) {
            my $channel = $_;
            for (my $multiple = 2; $multiple <= 4; $multiple += 2) {
                buildMultipleResampleFunc($from, $channel, 1, $multiple);
                buildMultipleResampleFunc($from, $channel, 0, $multiple);
            }
        }
    }

    print "#endif  /* !LESS_RESAMPLERS */\n";
    print "#endif  /* !NO_RESAMPLERS */\n\n\n";

    print "const SDL_AudioRateFilters sdl_audio_rate_filters[] =\n{\n";
    print "#if !NO_RESAMPLERS\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@channels) {
            my $channel = $_;
            for (my $upsample = 0; $upsample <= 1; $upsample++) {
                my $hashid = getResamplerHashId($from, $channel, $upsample, 0);
                my $sym = $funcs{$hashid};
                print("    { AUDIO_$from, $channel, $upsample, 0, $sym },\n");
            }
        }
    }

    print "#if !LESS_RESAMPLERS\n";
    foreach (@audiotypes) {
        my $from = $_;
        foreach (@channels) {
            my $channel = $_;
            for (my $multiple = 2; $multiple <= 4; $multiple += 2) {
                for (my $upsample = 0; $upsample <= 1; $upsample++) {
                    my $hashid = getResamplerHashId($from, $channel, $upsample, $multiple);
                    my $sym = $funcs{$hashid};
                    print("    { AUDIO_$from, $channel, $upsample, $multiple, $sym },\n");
                }
            }
        }
    }

    print "#endif  /* !LESS_RESAMPLERS */\n";
    print "#endif  /* !NO_RESAMPLERS */\n";
    print("    { 0, 0, 0, 0, NULL }\n");
    print "};\n\n";
}


# mainline ...

outputHeader();
buildTypeConverters();
buildResamplers();
outputFooter();

exit 0;

# end of sdlgenaudiocvt.pl ...
