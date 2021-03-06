# === DOCKER-SPECIFIC HACKERY ===

FROM hgrasland/acts-tests:debug
LABEL Description="openSUSE Tumbleweed with ACTS and Verrou" Version="2.0"
CMD bash


# === SYSTEM SETUP ===

# Update the host system
RUN zypper ref && zypper dup -y

# Install valgrind's run-time prerequisites (hack? what hack?)
RUN zypper in -y valgrind valgrind-devel && zypper rm -y valgrind valgrind-devel

# Install valgrind's additional build prerequisites
RUN zypper in -y subversion automake which

# Install verrou's additional build prerequisites
RUN zypper in -y patch


# === INSTALL VERROU ===

# Download the valgrind source code (currently using v3.13.0)
RUN svn co --quiet svn://svn.valgrind.org/valgrind/tags/VALGRIND_3_13_0 valgrind

# Download verrou and patch valgrind
RUN cd valgrind                                                                \
    && git clone --branch=v2.0.0 --depth 1                                     \
                 https://github.com/edf-hpc/verrou.git verrou                  \
    && patch -p0 < verrou/valgrind.diff

# Configure valgrind
#
# NOTE: You may need to remove the --enable-verrou-fma switch if you are using
#       an old CPU or virtual machine
#
RUN cd valgrind                                                                \
    && ./autogen.sh                                                            \
    && ./configure --enable-only64bit --enable-verrou-fma=yes

# Build and install valgrind
RUN cd valgrind                                                                \
    && make -j8                                                                \
    && make install

# Run the verrou test suite to check that everything is fine
RUN cd valgrind                                                                \
    && make -C tests check                                                     \
    && make -C verrou check                                                    \
    && perl tests/vg_regtest verrou                                            \
    && make -C verrou/unitTest

# Clean up after ourselves
RUN rm -rf valgrind


# === TEST ACTS WITH VERROU ===

# Rebuild the ACTS unit and integration tests
RUN cd acts-core/build && ninja

# Bring the files needed for verrou-based testing
COPY run.sh cmp.sh libm.ex /root/acts-core/build/IntegrationTests/

# Run the ACTS unit tests inside of Verrou
RUN cd acts-core/build                                                         \
    && valgrind --tool=verrou                                                  \
                --rounding-mode=random                                         \
                --demangle=no                                                  \
                --exclude=IntegrationTests/libm.ex                             \
                ctest -j8

# Run the ACTS integration tests inside of verrou
RUN cd acts-core/build/IntegrationTests                                        \
    && valgrind --tool=verrou                                                  \
                --rounding-mode=random                                         \
                --demangle=no                                                  \
                --exclude=libm.ex                                              \
                ./PropagationTests                                             \
    && valgrind --tool=verrou                                                  \
                --rounding-mode=random                                         \
                --demangle=no                                                  \
                --exclude=libm.ex                                              \
                ./SeedingTest

# Delta-debug the ACTS propagation to find its numerical instability regions.
# This is how the libm exclusion file was generated.
#
# NOTE: In principle, delta-debugging should go down to the granularity of
#       individual source lines, but this currently fails. I think that is
#       because the instabilities are in the libm and I do not have debugging
#       symbols for that. But since we already know that the libm trigonometric
#       function instabilities are a false alarm, this is not a big deal.
#
RUN cd acts-core/build/IntegrationTests                                        \
    && chmod +x run.sh cmp.sh                                                  \
    && verrou_dd run.sh cmp.sh

# Get rid of the largest delta-debugging artifacts
RUN cd acts-core/build/IntegrationTests && rm -rf dd.sym

# Clean up the ACTS build again to save space in the final image
RUN cd acts-core/build && ninja clean


# === FINAL CLEAN UP ===

# Discard the system package cache to save up space
RUN zypper clean