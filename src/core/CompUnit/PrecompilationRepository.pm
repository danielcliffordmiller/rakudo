{
    my $i;
    role CompUnit::PrecompilationRepository {
        has $!i = $i++;

        method load(CompUnit::PrecompilationId $id) returns CompUnit {
            CompUnit
        }

        method may-precomp() {
            $i < 3 # number of next repo after None and the first Default
        }
    }
}

BEGIN CompUnit::PrecompilationRepository::<None> := CompUnit::PrecompilationRepository.new;

class CompUnit { ... }
class CompUnit::PrecompilationRepository::Default does CompUnit::PrecompilationRepository {
    has CompUnit::PrecompilationStore $.store;

    method !check-dependencies(CompUnit::PrecompilationId $id, Instant $since) {
        for self.store.prefix.child('dependencies').lines -> $line {
            my ($dependent, @dependencies) = $line.split(' ');
            return not self.store.path($*PERL.compiler.id, any @dependencies).modified < $since
                if $id eq $dependent;
        }
        True
    }

    method load(CompUnit::PrecompilationId $id, Instant :$since) returns CompUnit::Handle {
        my $path = self.store.load($*PERL.compiler.id, $id);
        if $path {
            if not $since or $path.modified > $since and self!check-dependencies($id, $since) {
                my $preserve_global := nqp::ifnull(nqp::gethllsym('perl6', 'GLOBAL'), Mu);
                my $handle := CompUnit::Loader.load-precompilation-file($path);
                self.store.unlock;
                nqp::bindhllsym('perl6', 'GLOBAL', $preserve_global);
                CATCH {
                    default {
                        nqp::bindhllsym('perl6', 'GLOBAL', $preserve_global);
                        .throw;
                    }
                }
                $handle
            }
            else {
                self.store.unlock;
                CompUnit::Handle
            }
        }
        else {
            CompUnit::Handle
        }
    }

    method precompile(IO::Path:D $path, CompUnit::PrecompilationId $id) {
        my $io = self.store.destination($*PERL.compiler.id, $id);
        if $io.e && $io.modified > $path.modified {
            # someone else got there first between us checking for existence
            # of the precomp file and write locking the store
            self.store.unlock;
            return True;
        }

        my Mu $opts := nqp::atkey(%*COMPILING, '%?OPTIONS');
        my $lle = !nqp::isnull($opts) && !nqp::isnull(nqp::atkey($opts, 'll-exception'))
          ?? ' --ll-exception'
          !! '';
        %*ENV<RAKUDO_PRECOMP_WITH> = $*REPO.repo-chain>>.path-spec.join(',');

RAKUDO_MODULE_DEBUG("Precomping with %*ENV<RAKUDO_PRECOMP_WITH>")
  if $*RAKUDO_MODULE_DEBUG;

        my $cmd = "$*EXECUTABLE$lle --target={$*VM.precomp-target} --output=$io $path";
        my $proc = shell("$cmd 2>&1", :out);
        %*ENV<RAKUDO_PRECOMP_WITH>:delete;

        my @result = $proc.out.lines;
        if not $proc.out.close or $proc.status {  # something wrong
            self.store.unlock;
            push @result, "Return status $proc.status\n";
            fail @result if @result;
        }
        else {
            spurt(self.store.prefix.child('dependencies'), ($id, |@result).join(' ') ~ "\n", :append);
            self.store.unlock;
            True
        }
    }
}

# vim: ft=perl6 expandtab sw=4
