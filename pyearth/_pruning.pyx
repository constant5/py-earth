# distutils: language = c
# cython: cdivision = True
# cython: boundscheck = False
# cython: wraparound = False
# cython: profile = False

from ._record cimport PruningPassIteration
from ._util cimport gcv, apply_weights_2d
import numpy as np

cdef class PruningPasser:
    '''Implements the generic pruning pass as described by Friedman, 1991.'''
    def __init__(PruningPasser self, Basis basis,
                 cnp.ndarray[FLOAT_t, ndim=2] X, 
                 cnp.ndarray[BOOL_t, ndim=2] missing, 
                 cnp.ndarray[FLOAT_t, ndim=2] y,
                 cnp.ndarray[FLOAT_t, ndim=2] sample_weight, bint verbose,
                 **kwargs):
        self.X = X
        self.missing = missing
        self.m = self.X.shape[0]
        self.n = self.X.shape[1]
        self.y = y
        self.sample_weight = sample_weight
        self.verbose = verbose
        self.basis = basis
        self.B = np.empty(shape=(self.m, len(self.basis) + 1), dtype=np.float)
        self.penalty = kwargs.get('penalty', 3.0)
        if sample_weight.shape[1] == 1:
            y_avg = np.average(self.y, weights=sample_weight[:,0], axis=0)
        else:
            y_avg = np.average(self.y, weights=sample_weight, axis=0)

    cpdef run(PruningPasser self):
        # This is a totally naive implementation and could potentially be made
        # faster through the use of updating algorithms.  It is not clear that
        # such optimization would be worthwhile, as the pruning pass is not the
        # slowest part of the algorithm.
        cdef INDEX_t i
        cdef INDEX_t j
        cdef INDEX_t basis_size = len(self.basis)
        cdef INDEX_t pruned_basis_size = self.basis.plen()
        cdef FLOAT_t gcv_
        cdef INDEX_t best_iteration
        cdef INDEX_t best_bf_to_prune
        cdef FLOAT_t best_gcv
        cdef FLOAT_t best_iteration_gcv
        cdef FLOAT_t best_iteration_mse

        cdef cnp.ndarray[FLOAT_t, ndim = 2] B = (
            <cnp.ndarray[FLOAT_t, ndim = 2] > self.B)
        cdef cnp.ndarray[FLOAT_t, ndim = 2] X = (
            <cnp.ndarray[FLOAT_t, ndim = 2] > self.X)
        cdef cnp.ndarray[BOOL_t, ndim = 2] missing = (
            <cnp.ndarray[BOOL_t, ndim = 2] > self.missing)
        cdef cnp.ndarray[FLOAT_t, ndim = 2] y = (
            <cnp.ndarray[FLOAT_t, ndim = 2] > self.y)
        cdef cnp.ndarray[FLOAT_t, ndim = 2] sample_weight = (
            <cnp.ndarray[FLOAT_t, ndim = 2] > self.sample_weight)
        cdef cnp.ndarray[FLOAT_t, ndim = 1] weighted_y

        if self.verbose:
            print 'Beginning pruning pass'

        # Initial solution
        mse = 0.
        mse0 = 0.
        for p in range(y.shape[1]):
            if sample_weight.shape[1] == 1:
                weighted_y = y[:,p] * np.sqrt(sample_weight[:,0])
                self.basis.weighted_transform(X, missing, B, sample_weight[:, 0])
            else:
                weighted_y = y[:,p] * np.sqrt(sample_weight[:,p])
                self.basis.weighted_transform(X, missing, B, sample_weight[:, p])
#                 total_weight += np.sum(sample_weight[:,p])
            mse0 += np.sum((weighted_y - np.average(weighted_y)) ** 2)
            if sample_weight.shape[1] == 1:
                self.basis.weighted_transform(X, missing, B, sample_weight[:, 0])
            else:
                self.basis.weighted_transform(X, missing, B, sample_weight[:, p])
            beta, mse_ = np.linalg.lstsq(B[:, 0:(basis_size)], weighted_y)[0:2]
            if mse_:
                pass
            else:
                mse_ = np.sum(
                    (np.dot(B[:, 0:basis_size], beta) - weighted_y) ** 2)
            mse += mse_
        
        # Create the record object
        self.record = PruningPassRecord(
            self.m, self.n, self.penalty, mse0, pruned_basis_size, mse)
        gcv_ = self.record.gcv(0)
        best_gcv = gcv_
        best_iteration = 0
        
        if self.verbose:
            print self.record.partial_str(slice(-1, None, None), print_footer=False)

        # Prune basis functions sequentially
        for i in range(1, pruned_basis_size):
            first = True
            pruned_basis_size -= 1

            # Find the best basis function to prune
            for j in range(basis_size):
                bf = self.basis[j]
                if bf.is_pruned():
                    continue
                if not bf.is_prunable():
                    continue
                bf.prune()
                

                mse = 0.
                for p in range(y.shape[1]):
                    if sample_weight.shape[1] == 1:
                        weighted_y = y[:,p] * np.sqrt(sample_weight[:,0])
                        self.basis.weighted_transform(X, missing, B, sample_weight[:, 0])
                    else:
                        weighted_y = y[:,p] * np.sqrt(sample_weight[:,p])
                        self.basis.weighted_transform(X, missing, B, sample_weight[:, p])
                    beta, mse_ = np.linalg.lstsq(
                        B[:, 0:pruned_basis_size], weighted_y)[0:2]
                    if mse_:
                        pass
#                         mse_ /= np.sum(self.sample_weight)
                    else:
                        mse_ = np.sum((np.dot(B[:, 0:pruned_basis_size], beta) -
                                    weighted_y) ** 2) #/ np.sum(sample_weight)
                    mse += mse_# * output_weight[p]
                gcv_ = gcv(mse / np.sum(sample_weight), pruned_basis_size, self.m, self.penalty)

                if gcv_ <= best_iteration_gcv or first:
                    best_iteration_gcv = gcv_
                    best_iteration_mse = mse
                    best_bf_to_prune = j
                    first = False
                bf.unprune()

            # The inner loop found the best basis function to remove for this
            # iteration. Now check whether this iteration is better than all
            # the previous ones.
            if best_iteration_gcv <= best_gcv:
                best_gcv = best_iteration_gcv
                best_iteration = i

            # Update the record and prune the selected basis function
            self.record.append(PruningPassIteration(
                best_bf_to_prune, pruned_basis_size, best_iteration_mse))
            self.basis[best_bf_to_prune].prune()
            
            if self.verbose:
                print self.record.partial_str(slice(-1, None, None), print_header=False, print_footer=False)

        # Unprune the basis functions pruned after the best iteration
        self.record.set_selected(best_iteration)
        self.record.roll_back(self.basis)

    cpdef PruningPassRecord trace(PruningPasser self):
        return self.record
