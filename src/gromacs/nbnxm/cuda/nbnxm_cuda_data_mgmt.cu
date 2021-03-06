/*
 * This file is part of the GROMACS molecular simulation package.
 *
 * Copyright (c) 2012,2013,2014,2015,2016 by the GROMACS development team.
 * Copyright (c) 2017,2018,2019,2020, by the GROMACS development team, led by
 * Mark Abraham, David van der Spoel, Berk Hess, and Erik Lindahl,
 * and including many others, as listed in the AUTHORS file in the
 * top-level source directory and at http://www.gromacs.org.
 *
 * GROMACS is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * GROMACS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with GROMACS; if not, see
 * http://www.gnu.org/licenses, or write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA.
 *
 * If you want to redistribute modifications to GROMACS, please
 * consider that scientific software is very special. Version
 * control is crucial - bugs must be traceable. We will be happy to
 * consider code for inclusion in the official distribution, but
 * derived work must not be called official GROMACS. Details are found
 * in the README & COPYING files - if they are missing, get the
 * official version at http://www.gromacs.org.
 *
 * To help us fund GROMACS development, we humbly ask that you cite
 * the research papers on the package. Check out http://www.gromacs.org.
 */
/*! \file
 *  \brief Define CUDA implementation of nbnxn_gpu_data_mgmt.h
 *
 *  \author Szilard Pall <pall.szilard@gmail.com>
 */
#include "gmxpre.h"

#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

// TODO We would like to move this down, but the way NbnxmGpu
//      is currently declared means this has to be before gpu_types.h
#include "nbnxm_cuda_types.h"

// TODO Remove this comment when the above order issue is resolved
#include "gromacs/gpu_utils/cudautils.cuh"
#include "gromacs/gpu_utils/device_stream_manager.h"
#include "gromacs/gpu_utils/gpu_utils.h"
#include "gromacs/gpu_utils/gpueventsynchronizer.cuh"
#include "gromacs/gpu_utils/pmalloc_cuda.h"
#include "gromacs/hardware/gpu_hw_info.h"
#include "gromacs/math/vectypes.h"
#include "gromacs/mdlib/force_flags.h"
#include "gromacs/mdtypes/interaction_const.h"
#include "gromacs/mdtypes/md_enums.h"
#include "gromacs/nbnxm/atomdata.h"
#include "gromacs/nbnxm/gpu_data_mgmt.h"
#include "gromacs/nbnxm/gridset.h"
#include "gromacs/nbnxm/nbnxm.h"
#include "gromacs/nbnxm/nbnxm_gpu.h"
#include "gromacs/nbnxm/pairlistsets.h"
#include "gromacs/pbcutil/ishift.h"
#include "gromacs/timing/gpu_timing.h"
#include "gromacs/utility/basedefinitions.h"
#include "gromacs/utility/cstringutil.h"
#include "gromacs/utility/fatalerror.h"
#include "gromacs/utility/real.h"
#include "gromacs/utility/smalloc.h"

#include "nbnxm_cuda.h"

namespace Nbnxm
{

/* This is a heuristically determined parameter for the Kepler
 * and Maxwell architectures for the minimum size of ci lists by multiplying
 * this constant with the # of multiprocessors on the current device.
 * Since the maximum number of blocks per multiprocessor is 16, the ideal
 * count for small systems is 32 or 48 blocks per multiprocessor. Because
 * there is a bit of fluctuations in the generated block counts, we use
 * a target of 44 instead of the ideal value of 48.
 */
static unsigned int gpu_min_ci_balanced_factor = 44;

/* Fw. decl. */
static void nbnxn_cuda_clear_e_fshift(NbnxmGpu* nb);

/* Fw. decl, */
static void nbnxn_cuda_free_nbparam_table(cu_nbparam_t* nbparam);

/*! \brief Initialized the Ewald Coulomb correction GPU table.

    Tabulates the Ewald Coulomb force and initializes the size/scale
    and the table GPU array. If called with an already allocated table,
    it just re-uploads the table.
 */
static void init_ewald_coulomb_force_table(const EwaldCorrectionTables& tables,
                                           cu_nbparam_t*                nbp,
                                           const DeviceContext&         deviceContext)
{
    if (nbp->coulomb_tab != nullptr)
    {
        nbnxn_cuda_free_nbparam_table(nbp);
    }

    nbp->coulomb_tab_scale = tables.scale;
    initParamLookupTable(&nbp->coulomb_tab, &nbp->coulomb_tab_texobj, tables.tableF.data(),
                         tables.tableF.size(), deviceContext);
}


/*! Initializes the atomdata structure first time, it only gets filled at
    pair-search. */
static void init_atomdata_first(cu_atomdata_t* ad, int ntypes, const DeviceContext& deviceContext)
{
    ad->ntypes = ntypes;
    allocateDeviceBuffer(&ad->shift_vec, SHIFTS, deviceContext);
    ad->bShiftVecUploaded = false;

    allocateDeviceBuffer(&ad->fshift, SHIFTS, deviceContext);
    allocateDeviceBuffer(&ad->e_lj, 1, deviceContext);
    allocateDeviceBuffer(&ad->e_el, 1, deviceContext);

    /* initialize to nullptr poiters to data that is not allocated here and will
       need reallocation in nbnxn_cuda_init_atomdata */
    ad->xq = nullptr;
    ad->f  = nullptr;

    /* size -1 indicates that the respective array hasn't been initialized yet */
    ad->natoms = -1;
    ad->nalloc = -1;
}

/*! Selects the Ewald kernel type, analytical on SM 3.0 and later, tabulated on
    earlier GPUs, single or twin cut-off. */
static int pick_ewald_kernel_type(const interaction_const_t& ic)
{
    bool bTwinCut = (ic.rcoulomb != ic.rvdw);
    bool bUseAnalyticalEwald, bForceAnalyticalEwald, bForceTabulatedEwald;
    int  kernel_type;

    /* Benchmarking/development environment variables to force the use of
       analytical or tabulated Ewald kernel. */
    bForceAnalyticalEwald = (getenv("GMX_CUDA_NB_ANA_EWALD") != nullptr);
    bForceTabulatedEwald  = (getenv("GMX_CUDA_NB_TAB_EWALD") != nullptr);

    if (bForceAnalyticalEwald && bForceTabulatedEwald)
    {
        gmx_incons(
                "Both analytical and tabulated Ewald CUDA non-bonded kernels "
                "requested through environment variables.");
    }

    /* By default use analytical Ewald. */
    bUseAnalyticalEwald = true;
    if (bForceAnalyticalEwald)
    {
        if (debug)
        {
            fprintf(debug, "Using analytical Ewald CUDA kernels\n");
        }
    }
    else if (bForceTabulatedEwald)
    {
        bUseAnalyticalEwald = false;

        if (debug)
        {
            fprintf(debug, "Using tabulated Ewald CUDA kernels\n");
        }
    }

    /* Use twin cut-off kernels if requested by bTwinCut or the env. var.
       forces it (use it for debugging/benchmarking only). */
    if (!bTwinCut && (getenv("GMX_CUDA_NB_EWALD_TWINCUT") == nullptr))
    {
        kernel_type = bUseAnalyticalEwald ? eelTypeEWALD_ANA : eelTypeEWALD_TAB;
    }
    else
    {
        kernel_type = bUseAnalyticalEwald ? eelTypeEWALD_ANA_TWIN : eelTypeEWALD_TAB_TWIN;
    }

    return kernel_type;
}

/*! Copies all parameters related to the cut-off from ic to nbp */
static void set_cutoff_parameters(cu_nbparam_t* nbp, const interaction_const_t* ic, const PairlistParams& listParams)
{
    nbp->ewald_beta        = ic->ewaldcoeff_q;
    nbp->sh_ewald          = ic->sh_ewald;
    nbp->epsfac            = ic->epsfac;
    nbp->two_k_rf          = 2.0 * ic->k_rf;
    nbp->c_rf              = ic->c_rf;
    nbp->rvdw_sq           = ic->rvdw * ic->rvdw;
    nbp->rcoulomb_sq       = ic->rcoulomb * ic->rcoulomb;
    nbp->rlistOuter_sq     = listParams.rlistOuter * listParams.rlistOuter;
    nbp->rlistInner_sq     = listParams.rlistInner * listParams.rlistInner;
    nbp->useDynamicPruning = listParams.useDynamicPruning;

    nbp->sh_lj_ewald   = ic->sh_lj_ewald;
    nbp->ewaldcoeff_lj = ic->ewaldcoeff_lj;

    nbp->rvdw_switch      = ic->rvdw_switch;
    nbp->dispersion_shift = ic->dispersion_shift;
    nbp->repulsion_shift  = ic->repulsion_shift;
    nbp->vdw_switch       = ic->vdw_switch;
}

/*! Initializes the nonbonded parameter data structure. */
static void init_nbparam(cu_nbparam_t*                   nbp,
                         const interaction_const_t*      ic,
                         const PairlistParams&           listParams,
                         const nbnxn_atomdata_t::Params& nbatParams,
                         const DeviceContext&            deviceContext)
{
    int ntypes;

    ntypes = nbatParams.numTypes;

    set_cutoff_parameters(nbp, ic, listParams);

    /* The kernel code supports LJ combination rules (geometric and LB) for
     * all kernel types, but we only generate useful combination rule kernels.
     * We currently only use LJ combination rule (geometric and LB) kernels
     * for plain cut-off LJ. On Maxwell the force only kernels speed up 15%
     * with PME and 20% with RF, the other kernels speed up about half as much.
     * For LJ force-switch the geometric rule would give 7% speed-up, but this
     * combination is rarely used. LJ force-switch with LB rule is more common,
     * but gives only 1% speed-up.
     */
    if (ic->vdwtype == evdwCUT)
    {
        switch (ic->vdw_modifier)
        {
            case eintmodNONE:
            case eintmodPOTSHIFT:
                switch (nbatParams.comb_rule)
                {
                    case ljcrNONE: nbp->vdwtype = evdwTypeCUT; break;
                    case ljcrGEOM: nbp->vdwtype = evdwTypeCUTCOMBGEOM; break;
                    case ljcrLB: nbp->vdwtype = evdwTypeCUTCOMBLB; break;
                    default:
                        gmx_incons(
                                "The requested LJ combination rule is not implemented in the CUDA "
                                "GPU accelerated kernels!");
                }
                break;
            case eintmodFORCESWITCH: nbp->vdwtype = evdwTypeFSWITCH; break;
            case eintmodPOTSWITCH: nbp->vdwtype = evdwTypePSWITCH; break;
            default:
                gmx_incons(
                        "The requested VdW interaction modifier is not implemented in the CUDA GPU "
                        "accelerated kernels!");
        }
    }
    else if (ic->vdwtype == evdwPME)
    {
        if (ic->ljpme_comb_rule == ljcrGEOM)
        {
            assert(nbatParams.comb_rule == ljcrGEOM);
            nbp->vdwtype = evdwTypeEWALDGEOM;
        }
        else
        {
            assert(nbatParams.comb_rule == ljcrLB);
            nbp->vdwtype = evdwTypeEWALDLB;
        }
    }
    else
    {
        gmx_incons(
                "The requested VdW type is not implemented in the CUDA GPU accelerated kernels!");
    }

    if (ic->eeltype == eelCUT)
    {
        nbp->eeltype = eelTypeCUT;
    }
    else if (EEL_RF(ic->eeltype))
    {
        nbp->eeltype = eelTypeRF;
    }
    else if ((EEL_PME(ic->eeltype) || ic->eeltype == eelEWALD))
    {
        nbp->eeltype = pick_ewald_kernel_type(*ic);
    }
    else
    {
        /* Shouldn't happen, as this is checked when choosing Verlet-scheme */
        gmx_incons(
                "The requested electrostatics type is not implemented in the CUDA GPU accelerated "
                "kernels!");
    }

    /* generate table for PME */
    nbp->coulomb_tab = nullptr;
    if (nbp->eeltype == eelTypeEWALD_TAB || nbp->eeltype == eelTypeEWALD_TAB_TWIN)
    {
        GMX_RELEASE_ASSERT(ic->coulombEwaldTables, "Need valid Coulomb Ewald correction tables");
        init_ewald_coulomb_force_table(*ic->coulombEwaldTables, nbp, deviceContext);
    }

    /* set up LJ parameter lookup table */
    if (!useLjCombRule(nbp->vdwtype))
    {
        initParamLookupTable(&nbp->nbfp, &nbp->nbfp_texobj, nbatParams.nbfp.data(),
                             2 * ntypes * ntypes, deviceContext);
    }

    /* set up LJ-PME parameter lookup table */
    if (ic->vdwtype == evdwPME)
    {
        initParamLookupTable(&nbp->nbfp_comb, &nbp->nbfp_comb_texobj, nbatParams.nbfp_comb.data(),
                             2 * ntypes, deviceContext);
    }
}

/*! Re-generate the GPU Ewald force table, resets rlist, and update the
 *  electrostatic type switching to twin cut-off (or back) if needed. */
void gpu_pme_loadbal_update_param(const nonbonded_verlet_t* nbv, const interaction_const_t* ic)
{
    if (!nbv || !nbv->useGpu())
    {
        return;
    }
    NbnxmGpu*     nb  = nbv->gpu_nbv;
    cu_nbparam_t* nbp = nbv->gpu_nbv->nbparam;

    set_cutoff_parameters(nbp, ic, nbv->pairlistSets().params());

    nbp->eeltype = pick_ewald_kernel_type(*ic);

    GMX_RELEASE_ASSERT(ic->coulombEwaldTables, "Need valid Coulomb Ewald correction tables");
    init_ewald_coulomb_force_table(*ic->coulombEwaldTables, nbp, *nb->deviceContext_);
}

/*! Initializes the pair list data structure. */
static void init_plist(cu_plist_t* pl)
{
    /* initialize to nullptr pointers to data that is not allocated here and will
       need reallocation in nbnxn_gpu_init_pairlist */
    pl->sci   = nullptr;
    pl->cj4   = nullptr;
    pl->imask = nullptr;
    pl->excl  = nullptr;

    /* size -1 indicates that the respective array hasn't been initialized yet */
    pl->na_c          = -1;
    pl->nsci          = -1;
    pl->sci_nalloc    = -1;
    pl->ncj4          = -1;
    pl->cj4_nalloc    = -1;
    pl->nimask        = -1;
    pl->imask_nalloc  = -1;
    pl->nexcl         = -1;
    pl->excl_nalloc   = -1;
    pl->haveFreshList = false;
}

/*! Initializes the timings data structure. */
static void init_timings(gmx_wallclock_gpu_nbnxn_t* t)
{
    int i, j;

    t->nb_h2d_t = 0.0;
    t->nb_d2h_t = 0.0;
    t->nb_c     = 0;
    t->pl_h2d_t = 0.0;
    t->pl_h2d_c = 0;
    for (i = 0; i < 2; i++)
    {
        for (j = 0; j < 2; j++)
        {
            t->ktime[i][j].t = 0.0;
            t->ktime[i][j].c = 0;
        }
    }
    t->pruneTime.c        = 0;
    t->pruneTime.t        = 0.0;
    t->dynamicPruneTime.c = 0;
    t->dynamicPruneTime.t = 0.0;
}

/*! Initializes simulation constant data. */
static void cuda_init_const(NbnxmGpu*                       nb,
                            const interaction_const_t*      ic,
                            const PairlistParams&           listParams,
                            const nbnxn_atomdata_t::Params& nbatParams)
{
    init_atomdata_first(nb->atdat, nbatParams.numTypes, *nb->deviceContext_);
    init_nbparam(nb->nbparam, ic, listParams, nbatParams, *nb->deviceContext_);

    /* clear energy and shift force outputs */
    nbnxn_cuda_clear_e_fshift(nb);
}

NbnxmGpu* gpu_init(const gmx::DeviceStreamManager& deviceStreamManager,
                   const interaction_const_t*      ic,
                   const PairlistParams&           listParams,
                   const nbnxn_atomdata_t*         nbat,
                   bool                            bLocalAndNonlocal)
{
    cudaError_t stat;

    auto nb            = new NbnxmGpu();
    nb->deviceContext_ = &deviceStreamManager.context();
    snew(nb->atdat, 1);
    snew(nb->nbparam, 1);
    snew(nb->plist[InteractionLocality::Local], 1);
    if (bLocalAndNonlocal)
    {
        snew(nb->plist[InteractionLocality::NonLocal], 1);
    }

    nb->bUseTwoStreams = bLocalAndNonlocal;

    nb->timers = new cu_timers_t();
    snew(nb->timings, 1);

    /* init nbst */
    pmalloc((void**)&nb->nbst.e_lj, sizeof(*nb->nbst.e_lj));
    pmalloc((void**)&nb->nbst.e_el, sizeof(*nb->nbst.e_el));
    pmalloc((void**)&nb->nbst.fshift, SHIFTS * sizeof(*nb->nbst.fshift));

    init_plist(nb->plist[InteractionLocality::Local]);

    /* local/non-local GPU streams */
    GMX_RELEASE_ASSERT(deviceStreamManager.streamIsValid(gmx::DeviceStreamType::NonBondedLocal),
                       "Local non-bonded stream should be initialized to use GPU for non-bonded.");
    nb->deviceStreams[InteractionLocality::Local] =
            &deviceStreamManager.stream(gmx::DeviceStreamType::NonBondedLocal);
    if (nb->bUseTwoStreams)
    {
        init_plist(nb->plist[InteractionLocality::NonLocal]);

        /* Note that the device we're running on does not have to support
         * priorities, because we are querying the priority range which in this
         * case will be a single value.
         */
        GMX_RELEASE_ASSERT(deviceStreamManager.streamIsValid(gmx::DeviceStreamType::NonBondedNonLocal),
                           "Non-local non-bonded stream should be initialized to use GPU for "
                           "non-bonded with domain decomposition.");
        nb->deviceStreams[InteractionLocality::NonLocal] =
                &deviceStreamManager.stream(gmx::DeviceStreamType::NonBondedNonLocal);
        ;
    }

    /* init events for sychronization (timing disabled for performance reasons!) */
    stat = cudaEventCreateWithFlags(&nb->nonlocal_done, cudaEventDisableTiming);
    CU_RET_ERR(stat, "cudaEventCreate on nonlocal_done failed");
    stat = cudaEventCreateWithFlags(&nb->misc_ops_and_local_H2D_done, cudaEventDisableTiming);
    CU_RET_ERR(stat, "cudaEventCreate on misc_ops_and_local_H2D_done failed");

    nb->xNonLocalCopyD2HDone = new GpuEventSynchronizer();

    /* WARNING: CUDA timings are incorrect with multiple streams.
     *          This is the main reason why they are disabled by default.
     */
    // TODO: Consider turning on by default when we can detect nr of streams.
    nb->bDoTime = (getenv("GMX_ENABLE_GPU_TIMING") != nullptr);

    if (nb->bDoTime)
    {
        init_timings(nb->timings);
    }

    /* set the kernel type for the current GPU */
    /* pick L1 cache configuration */
    cuda_set_cacheconfig();

    cuda_init_const(nb, ic, listParams, nbat->params());

    nb->atomIndicesSize       = 0;
    nb->atomIndicesSize_alloc = 0;
    nb->ncxy_na               = 0;
    nb->ncxy_na_alloc         = 0;
    nb->ncxy_ind              = 0;
    nb->ncxy_ind_alloc        = 0;
    nb->ncell                 = 0;
    nb->ncell_alloc           = 0;

    if (debug)
    {
        fprintf(debug, "Initialized CUDA data structures.\n");
    }

    return nb;
}

void gpu_init_pairlist(NbnxmGpu* nb, const NbnxnPairlistGpu* h_plist, const InteractionLocality iloc)
{
    char                sbuf[STRLEN];
    bool                bDoTime      = (nb->bDoTime && !h_plist->sci.empty());
    const DeviceStream& deviceStream = *nb->deviceStreams[iloc];
    cu_plist_t*         d_plist      = nb->plist[iloc];

    if (d_plist->na_c < 0)
    {
        d_plist->na_c = h_plist->na_ci;
    }
    else
    {
        if (d_plist->na_c != h_plist->na_ci)
        {
            sprintf(sbuf, "In cu_init_plist: the #atoms per cell has changed (from %d to %d)",
                    d_plist->na_c, h_plist->na_ci);
            gmx_incons(sbuf);
        }
    }

    gpu_timers_t::Interaction& iTimers = nb->timers->interaction[iloc];

    if (bDoTime)
    {
        iTimers.pl_h2d.openTimingRegion(deviceStream);
        iTimers.didPairlistH2D = true;
    }

    const DeviceContext& deviceContext = *nb->deviceContext_;

    reallocateDeviceBuffer(&d_plist->sci, h_plist->sci.size(), &d_plist->nsci, &d_plist->sci_nalloc,
                           deviceContext);
    copyToDeviceBuffer(&d_plist->sci, h_plist->sci.data(), 0, h_plist->sci.size(), deviceStream,
                       GpuApiCallBehavior::Async, bDoTime ? iTimers.pl_h2d.fetchNextEvent() : nullptr);

    reallocateDeviceBuffer(&d_plist->cj4, h_plist->cj4.size(), &d_plist->ncj4, &d_plist->cj4_nalloc,
                           deviceContext);
    copyToDeviceBuffer(&d_plist->cj4, h_plist->cj4.data(), 0, h_plist->cj4.size(), deviceStream,
                       GpuApiCallBehavior::Async, bDoTime ? iTimers.pl_h2d.fetchNextEvent() : nullptr);

    reallocateDeviceBuffer(&d_plist->imask, h_plist->cj4.size() * c_nbnxnGpuClusterpairSplit,
                           &d_plist->nimask, &d_plist->imask_nalloc, deviceContext);

    reallocateDeviceBuffer(&d_plist->excl, h_plist->excl.size(), &d_plist->nexcl,
                           &d_plist->excl_nalloc, deviceContext);
    copyToDeviceBuffer(&d_plist->excl, h_plist->excl.data(), 0, h_plist->excl.size(), deviceStream,
                       GpuApiCallBehavior::Async, bDoTime ? iTimers.pl_h2d.fetchNextEvent() : nullptr);

    if (bDoTime)
    {
        iTimers.pl_h2d.closeTimingRegion(deviceStream);
    }

    /* the next use of thist list we be the first one, so we need to prune */
    d_plist->haveFreshList = true;
}

void gpu_upload_shiftvec(NbnxmGpu* nb, const nbnxn_atomdata_t* nbatom)
{
    cu_atomdata_t*      adat        = nb->atdat;
    const DeviceStream& localStream = *nb->deviceStreams[InteractionLocality::Local];

    /* only if we have a dynamic box */
    if (nbatom->bDynamicBox || !adat->bShiftVecUploaded)
    {
        static_assert(sizeof(adat->shift_vec[0]) == sizeof(nbatom->shift_vec[0]),
                      "Sizes of host- and device-side shift vectors should be the same.");
        copyToDeviceBuffer(&adat->shift_vec, reinterpret_cast<const float3*>(nbatom->shift_vec.data()),
                           0, SHIFTS, localStream, GpuApiCallBehavior::Async, nullptr);
        adat->bShiftVecUploaded = true;
    }
}

/*! Clears the first natoms_clear elements of the GPU nonbonded force output array. */
static void nbnxn_cuda_clear_f(NbnxmGpu* nb, int natoms_clear)
{
    cu_atomdata_t*      adat        = nb->atdat;
    const DeviceStream& localStream = *nb->deviceStreams[InteractionLocality::Local];
    clearDeviceBufferAsync(&adat->f, 0, natoms_clear, localStream);
}

/*! Clears nonbonded shift force output array and energy outputs on the GPU. */
static void nbnxn_cuda_clear_e_fshift(NbnxmGpu* nb)
{
    cu_atomdata_t*      adat        = nb->atdat;
    const DeviceStream& localStream = *nb->deviceStreams[InteractionLocality::Local];

    clearDeviceBufferAsync(&adat->fshift, 0, SHIFTS, localStream);
    clearDeviceBufferAsync(&adat->e_lj, 0, 1, localStream);
    clearDeviceBufferAsync(&adat->e_el, 0, 1, localStream);
}

void gpu_clear_outputs(NbnxmGpu* nb, bool computeVirial)
{
    nbnxn_cuda_clear_f(nb, nb->atdat->natoms);
    /* clear shift force array and energies if the outputs were
       used in the current step */
    if (computeVirial)
    {
        nbnxn_cuda_clear_e_fshift(nb);
    }
}

void gpu_init_atomdata(NbnxmGpu* nb, const nbnxn_atomdata_t* nbat)
{
    int                  nalloc, natoms;
    bool                 realloced;
    bool                 bDoTime       = nb->bDoTime;
    cu_timers_t*         timers        = nb->timers;
    cu_atomdata_t*       d_atdat       = nb->atdat;
    const DeviceContext& deviceContext = *nb->deviceContext_;
    const DeviceStream&  localStream   = *nb->deviceStreams[InteractionLocality::Local];

    natoms    = nbat->numAtoms();
    realloced = false;

    if (bDoTime)
    {
        /* time async copy */
        timers->atdat.openTimingRegion(localStream);
    }

    /* need to reallocate if we have to copy more atoms than the amount of space
       available and only allocate if we haven't initialized yet, i.e d_atdat->natoms == -1 */
    if (natoms > d_atdat->nalloc)
    {
        nalloc = over_alloc_small(natoms);

        /* free up first if the arrays have already been initialized */
        if (d_atdat->nalloc != -1)
        {
            freeDeviceBuffer(&d_atdat->f);
            freeDeviceBuffer(&d_atdat->xq);
            freeDeviceBuffer(&d_atdat->atom_types);
            freeDeviceBuffer(&d_atdat->lj_comb);
        }

        allocateDeviceBuffer(&d_atdat->f, nalloc, deviceContext);
        allocateDeviceBuffer(&d_atdat->xq, nalloc, deviceContext);
        if (useLjCombRule(nb->nbparam->vdwtype))
        {
            allocateDeviceBuffer(&d_atdat->lj_comb, nalloc, deviceContext);
        }
        else
        {
            allocateDeviceBuffer(&d_atdat->atom_types, nalloc, deviceContext);
        }

        d_atdat->nalloc = nalloc;
        realloced       = true;
    }

    d_atdat->natoms       = natoms;
    d_atdat->natoms_local = nbat->natoms_local;

    /* need to clear GPU f output if realloc happened */
    if (realloced)
    {
        nbnxn_cuda_clear_f(nb, nalloc);
    }

    if (useLjCombRule(nb->nbparam->vdwtype))
    {
        static_assert(sizeof(d_atdat->lj_comb[0]) == sizeof(float2),
                      "Size of the LJ parameters element should be equal to the size of float2.");
        copyToDeviceBuffer(&d_atdat->lj_comb,
                           reinterpret_cast<const float2*>(nbat->params().lj_comb.data()), 0,
                           natoms, localStream, GpuApiCallBehavior::Async, nullptr);
    }
    else
    {
        static_assert(sizeof(d_atdat->atom_types[0]) == sizeof(nbat->params().type[0]),
                      "Sizes of host- and device-side atom types should be the same.");
        copyToDeviceBuffer(&d_atdat->atom_types, nbat->params().type.data(), 0, natoms, localStream,
                           GpuApiCallBehavior::Async, nullptr);
    }

    if (bDoTime)
    {
        timers->atdat.closeTimingRegion(localStream);
    }
}

static void nbnxn_cuda_free_nbparam_table(cu_nbparam_t* nbparam)
{
    if (nbparam->eeltype == eelTypeEWALD_TAB || nbparam->eeltype == eelTypeEWALD_TAB_TWIN)
    {
        destroyParamLookupTable(&nbparam->coulomb_tab, nbparam->coulomb_tab_texobj);
    }
}

void gpu_free(NbnxmGpu* nb)
{
    cudaError_t    stat;
    cu_atomdata_t* atdat;
    cu_nbparam_t*  nbparam;

    if (nb == nullptr)
    {
        return;
    }

    atdat   = nb->atdat;
    nbparam = nb->nbparam;

    nbnxn_cuda_free_nbparam_table(nbparam);

    stat = cudaEventDestroy(nb->nonlocal_done);
    CU_RET_ERR(stat, "cudaEventDestroy failed on timers->nonlocal_done");
    stat = cudaEventDestroy(nb->misc_ops_and_local_H2D_done);
    CU_RET_ERR(stat, "cudaEventDestroy failed on timers->misc_ops_and_local_H2D_done");

    delete nb->timers;

    if (!useLjCombRule(nb->nbparam->vdwtype))
    {
        destroyParamLookupTable(&nbparam->nbfp, nbparam->nbfp_texobj);
    }

    if (nbparam->vdwtype == evdwTypeEWALDGEOM || nbparam->vdwtype == evdwTypeEWALDLB)
    {
        destroyParamLookupTable(&nbparam->nbfp_comb, nbparam->nbfp_comb_texobj);
    }

    freeDeviceBuffer(&atdat->shift_vec);
    freeDeviceBuffer(&atdat->fshift);

    freeDeviceBuffer(&atdat->e_lj);
    freeDeviceBuffer(&atdat->e_el);

    freeDeviceBuffer(&atdat->f);
    freeDeviceBuffer(&atdat->xq);
    freeDeviceBuffer(&atdat->atom_types);
    freeDeviceBuffer(&atdat->lj_comb);

    /* Free plist */
    auto* plist = nb->plist[InteractionLocality::Local];
    freeDeviceBuffer(&plist->sci);
    freeDeviceBuffer(&plist->cj4);
    freeDeviceBuffer(&plist->imask);
    freeDeviceBuffer(&plist->excl);
    sfree(plist);
    if (nb->bUseTwoStreams)
    {
        auto* plist_nl = nb->plist[InteractionLocality::NonLocal];
        freeDeviceBuffer(&plist_nl->sci);
        freeDeviceBuffer(&plist_nl->cj4);
        freeDeviceBuffer(&plist_nl->imask);
        freeDeviceBuffer(&plist_nl->excl);
        sfree(plist_nl);
    }

    /* Free nbst */
    pfree(nb->nbst.e_lj);
    nb->nbst.e_lj = nullptr;

    pfree(nb->nbst.e_el);
    nb->nbst.e_el = nullptr;

    pfree(nb->nbst.fshift);
    nb->nbst.fshift = nullptr;

    sfree(atdat);
    sfree(nbparam);
    sfree(nb->timings);
    delete nb;

    if (debug)
    {
        fprintf(debug, "Cleaned up CUDA data structures.\n");
    }
}

//! This function is documented in the header file
gmx_wallclock_gpu_nbnxn_t* gpu_get_timings(NbnxmGpu* nb)
{
    return (nb != nullptr && nb->bDoTime) ? nb->timings : nullptr;
}

void gpu_reset_timings(nonbonded_verlet_t* nbv)
{
    if (nbv->gpu_nbv && nbv->gpu_nbv->bDoTime)
    {
        init_timings(nbv->gpu_nbv->timings);
    }
}

int gpu_min_ci_balanced(NbnxmGpu* nb)
{
    return nb != nullptr ? gpu_min_ci_balanced_factor * nb->deviceContext_->deviceInfo().prop.multiProcessorCount
                         : 0;
}

gmx_bool gpu_is_kernel_ewald_analytical(const NbnxmGpu* nb)
{
    return ((nb->nbparam->eeltype == eelTypeEWALD_ANA) || (nb->nbparam->eeltype == eelTypeEWALD_ANA_TWIN));
}

void* gpu_get_xq(NbnxmGpu* nb)
{
    assert(nb);

    return static_cast<void*>(nb->atdat->xq);
}

DeviceBuffer<gmx::RVec> gpu_get_f(NbnxmGpu* nb)
{
    assert(nb);

    return reinterpret_cast<DeviceBuffer<gmx::RVec>>(nb->atdat->f);
}

DeviceBuffer<gmx::RVec> gpu_get_fshift(NbnxmGpu* nb)
{
    assert(nb);

    return reinterpret_cast<DeviceBuffer<gmx::RVec>>(nb->atdat->fshift);
}

/* Initialization for X buffer operations on GPU. */
/* TODO  Remove explicit pinning from host arrays from here and manage in a more natural way*/
void nbnxn_gpu_init_x_to_nbat_x(const Nbnxm::GridSet& gridSet, NbnxmGpu* gpu_nbv)
{
    const DeviceStream& deviceStream  = *gpu_nbv->deviceStreams[InteractionLocality::Local];
    bool                bDoTime       = gpu_nbv->bDoTime;
    const int           maxNumColumns = gridSet.numColumnsMax();

    reallocateDeviceBuffer(&gpu_nbv->cxy_na, maxNumColumns * gridSet.grids().size(),
                           &gpu_nbv->ncxy_na, &gpu_nbv->ncxy_na_alloc, *gpu_nbv->deviceContext_);
    reallocateDeviceBuffer(&gpu_nbv->cxy_ind, maxNumColumns * gridSet.grids().size(),
                           &gpu_nbv->ncxy_ind, &gpu_nbv->ncxy_ind_alloc, *gpu_nbv->deviceContext_);

    for (unsigned int g = 0; g < gridSet.grids().size(); g++)
    {

        const Nbnxm::Grid& grid = gridSet.grids()[g];

        const int  numColumns      = grid.numColumns();
        const int* atomIndices     = gridSet.atomIndices().data();
        const int  atomIndicesSize = gridSet.atomIndices().size();
        const int* cxy_na          = grid.cxy_na().data();
        const int* cxy_ind         = grid.cxy_ind().data();

        reallocateDeviceBuffer(&gpu_nbv->atomIndices, atomIndicesSize, &gpu_nbv->atomIndicesSize,
                               &gpu_nbv->atomIndicesSize_alloc, *gpu_nbv->deviceContext_);

        if (atomIndicesSize > 0)
        {

            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.openTimingRegion(deviceStream);
            }

            copyToDeviceBuffer(&gpu_nbv->atomIndices, atomIndices, 0, atomIndicesSize, deviceStream,
                               GpuApiCallBehavior::Async, nullptr);

            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.closeTimingRegion(deviceStream);
            }
        }

        if (numColumns > 0)
        {
            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.openTimingRegion(deviceStream);
            }

            int* destPtr = &gpu_nbv->cxy_na[maxNumColumns * g];
            copyToDeviceBuffer(&destPtr, cxy_na, 0, numColumns, deviceStream,
                               GpuApiCallBehavior::Async, nullptr);

            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.closeTimingRegion(deviceStream);
            }

            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.openTimingRegion(deviceStream);
            }

            destPtr = &gpu_nbv->cxy_ind[maxNumColumns * g];
            copyToDeviceBuffer(&destPtr, cxy_ind, 0, numColumns, deviceStream,
                               GpuApiCallBehavior::Async, nullptr);

            if (bDoTime)
            {
                gpu_nbv->timers->xf[AtomLocality::Local].nb_h2d.closeTimingRegion(deviceStream);
            }
        }
    }

    // The above data is transferred on the local stream but is a
    // dependency of the nonlocal stream (specifically the nonlocal X
    // buf ops kernel).  We therefore set a dependency to ensure
    // that the nonlocal stream waits on the local stream here.
    // This call records an event in the local stream:
    nbnxnInsertNonlocalGpuDependency(gpu_nbv, Nbnxm::InteractionLocality::Local);
    // ...and this call instructs the nonlocal stream to wait on that event:
    nbnxnInsertNonlocalGpuDependency(gpu_nbv, Nbnxm::InteractionLocality::NonLocal);

    return;
}

/* Initialization for F buffer operations on GPU. */
void nbnxn_gpu_init_add_nbat_f_to_f(const int*                  cell,
                                    NbnxmGpu*                   gpu_nbv,
                                    int                         natoms_total,
                                    GpuEventSynchronizer* const localReductionDone)
{

    const DeviceStream& deviceStream = *gpu_nbv->deviceStreams[InteractionLocality::Local];

    GMX_ASSERT(localReductionDone, "localReductionDone should be a valid pointer");
    gpu_nbv->localFReductionDone = localReductionDone;

    if (natoms_total > 0)
    {
        reallocateDeviceBuffer(&gpu_nbv->cell, natoms_total, &gpu_nbv->ncell, &gpu_nbv->ncell_alloc,
                               *gpu_nbv->deviceContext_);
        copyToDeviceBuffer(&gpu_nbv->cell, cell, 0, natoms_total, deviceStream,
                           GpuApiCallBehavior::Async, nullptr);
    }

    return;
}

} // namespace Nbnxm
